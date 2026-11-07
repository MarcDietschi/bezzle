import Foundation

// SHA-256, which is all Bezzle's shared code takes from CryptoKit: for a library's fingerprint,
// and the names of the pictures a Photoshop document brings in. As CryptoKit's, it is told the
// data in parts (`update`) or all at once (`hash`).
nonisolated public struct SHA256: Sendable {
    public struct Digest: Sequence, Sendable {
        public let bytes: [UInt8]
        public func makeIterator() -> IndexingIterator<[UInt8]> { bytes.makeIterator() }
        public func prefix(_ n: Int) -> ArraySlice<UInt8> { bytes.prefix(n) }
    }

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    /// What is told but not yet a whole block of 64 bytes.
    private var waiting: [UInt8] = []
    private var length: UInt64 = 0

    public init() {}

    public mutating func update<D: DataProtocol>(data: D) {
        length &+= UInt64(data.count)
        for region in data.regions {
            if region.withContiguousStorageIfAvailable({ feed($0) }) == nil { feed(Array(region)) }
        }
    }

    private mutating func feed(_ bytes: [UInt8]) { bytes.withUnsafeBufferPointer { feed($0) } }

    private mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard var p = bytes.baseAddress else { return }
        var n = bytes.count
        if !waiting.isEmpty {
            let take = min(64 - waiting.count, n)
            waiting.append(contentsOf: UnsafeBufferPointer(start: p, count: take))
            p += take
            n -= take
            guard waiting.count == 64 else { return }
            waiting.withUnsafeBufferPointer { block($0.baseAddress!) }
            waiting.removeAll(keepingCapacity: true)
        }
        while n >= 64 {
            block(p)
            p += 64
            n -= 64
        }
        if n > 0 { waiting.append(contentsOf: UnsafeBufferPointer(start: p, count: n)) }
    }

    public func finalize() -> Digest {
        var copy = self
        var tail: [UInt8] = [0x80]
        while (copy.waiting.count + tail.count) % 64 != 56 { tail.append(0) }
        let bits = length &* 8
        for i in (0..<8).reversed() { tail.append(UInt8(truncatingIfNeeded: bits >> (UInt64(i) * 8))) }
        copy.feed(tail)
        return Digest(bytes: copy.h.flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - $0 * 8)) } })
    }

    public static func hash<D: DataProtocol>(data: D) -> Digest {
        var hasher = SHA256()
        hasher.update(data: data)
        return hasher.finalize()
    }

    /// One block of 64 bytes.
    private mutating func block(_ m: UnsafePointer<UInt8>) {
        @inline(__always) func r(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { w in
            var i = 0
            while i < 16 {
                w[i] = UInt32(m[i * 4]) << 24 | UInt32(m[i * 4 + 1]) << 16 | UInt32(m[i * 4 + 2]) << 8 | UInt32(m[i * 4 + 3])
                i += 1
            }
            while i < 64 {
                let s0 = r(w[i - 15], 7) ^ r(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = r(w[i - 2], 17) ^ r(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
                i += 1
            }
            Self.k.withUnsafeBufferPointer { k in
                h.withUnsafeMutableBufferPointer { h in
                    var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
                    var j = 0
                    while j < 64 {
                        let t1 = hh &+ (r(e, 6) ^ r(e, 11) ^ r(e, 25)) &+ ((e & f) ^ (~e & g)) &+ k[j] &+ w[j]
                        let t2 = (r(a, 2) ^ r(a, 13) ^ r(a, 22)) &+ ((a & b) ^ (a & c) ^ (b & c))
                        (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
                        j += 1
                    }
                    h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
                    h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
                }
            }
        }
    }
}
