import Foundation
import CBezzleHost

// What the shared Model/Live.swift takes from CryptoKit, on Windows: keys, HKDF and HMAC over
// SHA-256, and AES-256-GCM, shaped as CryptoKit's are so that ShareKeys seals and opens exactly as
// on the Mac (Relay/SHARING.md). The sealing itself is Windows' own (bcrypt.h, in
// CBezzleHost/sealing.cpp); HKDF is RFC 5869 over that HMAC. SHA-256 is the core's own
// (Platform/CryptoKit.swift).

/// The hash a key is derived or a code is made with: SHA-256 is the one there is.
nonisolated protocol HashFunction {}
nonisolated extension SHA256: HashFunction {}

nonisolated struct SymmetricKey: Sendable {
    fileprivate let bytes: [UInt8]

    init<D: DataProtocol>(data: D) { bytes = Array(data) }

    var bitCount: Int { bytes.count * 8 }

    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeBytes(body)
    }
}

nonisolated struct HashedAuthenticationCode<H: HashFunction>: Sequence, Sendable {
    fileprivate let bytes: [UInt8]
    func makeIterator() -> IndexingIterator<[UInt8]> { bytes.makeIterator() }
}

nonisolated enum HMAC<H: HashFunction> {
    static func authenticationCode<D: DataProtocol>(for data: D, using key: SymmetricKey) -> HashedAuthenticationCode<H> {
        HashedAuthenticationCode(bytes: Sealing.hmac(key: key.bytes, Array(data)))
    }
}

nonisolated enum HKDF<H: HashFunction> {
    /// RFC 5869: extract with the salt, then expand with the info, as CryptoKit's does.
    static func deriveKey<S: DataProtocol, I: DataProtocol>(inputKeyMaterial: SymmetricKey, salt: S, info: I, outputByteCount: Int) -> SymmetricKey {
        let salt = Array(salt)
        // No salt is a salt of noughts as long as the hash.
        let prk = Sealing.hmac(key: salt.isEmpty ? [UInt8](repeating: 0, count: 32) : salt, inputKeyMaterial.bytes)
        let info = Array(info)
        var out: [UInt8] = [], t: [UInt8] = [], i: UInt8 = 1
        while out.count < outputByteCount {
            t = Sealing.hmac(key: prk, t + info + [i])
            out += t
            i &+= 1
        }
        return SymmetricKey(data: out.prefix(outputByteCount))
    }
}

nonisolated enum CryptoKitError: Swift.Error {
    case incorrectParameterSize
    case authenticationFailure
    case underlyingCoreCryptoError(error: Int32)
}

nonisolated enum AES {
    enum GCM {
        struct Nonce: Sendable {
            let bytes: [UInt8]

            init() {
                var random = SystemRandomNumberGenerator()
                bytes = (0..<12).map { _ in UInt8.random(in: .min ... .max, using: &random) }
            }

            init<D: DataProtocol>(data: D) throws {
                guard data.count == 12 else { throw CryptoKitError.incorrectParameterSize }
                bytes = Array(data)
            }
        }

        struct SealedBox: Sendable {
            let nonce: Nonce
            let ciphertext: Data
            let tag: Data

            /// Nonce, ciphertext and tag, one after the other, as CryptoKit combines them.
            var combined: Data? { Data(nonce.bytes) + ciphertext + tag }

            init<D: DataProtocol>(combined: D) throws {
                let all = Array(combined)
                guard all.count >= 12 + 16 else { throw CryptoKitError.incorrectParameterSize }
                nonce = try Nonce(data: all[0..<12])
                ciphertext = Data(all[12..<(all.count - 16)])
                tag = Data(all[(all.count - 16)...])
            }

            fileprivate init(nonce: Nonce, ciphertext: Data, tag: Data) {
                self.nonce = nonce
                self.ciphertext = ciphertext
                self.tag = tag
            }
        }

        static func seal<M: DataProtocol, A: DataProtocol>(_ message: M, using key: SymmetricKey, nonce: Nonce = Nonce(), authenticating aad: A) throws -> SealedBox {
            guard key.bytes.count == 32 else { throw CryptoKitError.incorrectParameterSize }
            let plain = Array(message), extra = Array(aad)
            var out = [UInt8](repeating: 0, count: plain.count), tag = [UInt8](repeating: 0, count: 16)
            let done = Sealing.gcm(seal: true, key: key.bytes, nonce: nonce.bytes, aad: extra, input: plain, output: &out, tag: &tag)
            guard done == 0 else { throw CryptoKitError.underlyingCoreCryptoError(error: done) }
            return SealedBox(nonce: nonce, ciphertext: Data(out), tag: Data(tag))
        }

        static func open<A: DataProtocol>(_ box: SealedBox, using key: SymmetricKey, authenticating aad: A) throws -> Data {
            guard key.bytes.count == 32 else { throw CryptoKitError.incorrectParameterSize }
            let sealed = Array(box.ciphertext), extra = Array(aad)
            var out = [UInt8](repeating: 0, count: sealed.count), tag = Array(box.tag)
            guard Sealing.gcm(seal: false, key: key.bytes, nonce: box.nonce.bytes, aad: extra, input: sealed, output: &out, tag: &tag) == 0 else {
                throw CryptoKitError.authenticationFailure
            }
            return Data(out)
        }
    }
}

/// The calls into Windows' own cryptography.
nonisolated enum Sealing {
    static func hmac(key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        let done = key.withUnsafeBufferPointer { k in
            data.withUnsafeBufferPointer { d in
                out.withUnsafeMutableBufferPointer { o in
                    bz_hmac_sha256(k.baseAddress, Int32(k.count), d.baseAddress, Int64(d.count), o.baseAddress)
                }
            }
        }
        // It cannot fail with a hash Windows has; were it ever to, nothing would open.
        return done == 0 ? out : []
    }

    static func gcm(seal: Bool, key: [UInt8], nonce: [UInt8], aad: [UInt8], input: [UInt8], output: inout [UInt8], tag: inout [UInt8]) -> Int32 {
        key.withUnsafeBufferPointer { k in
            nonce.withUnsafeBufferPointer { n in
                aad.withUnsafeBufferPointer { a in
                    input.withUnsafeBufferPointer { i in
                        output.withUnsafeMutableBufferPointer { o in
                            tag.withUnsafeMutableBufferPointer { t in
                                bz_gcm(seal ? 1 : 0, k.baseAddress, n.baseAddress, a.baseAddress, Int32(a.count), i.baseAddress, Int64(i.count), o.baseAddress, t.baseAddress)
                            }
                        }
                    }
                }
            }
        }
    }
}
