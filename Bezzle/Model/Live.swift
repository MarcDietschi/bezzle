import Foundation
import CoreGraphics
import CoreImage
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// Working on a shared design at the same moment: everyone's hand, gaze and changes as they
// happen, passed between the Macs that have it open by a relay that cannot read them. The
// design's records on the relay, or the synced folder it is kept in, keep it; this only makes
// it quick. See `LiveRoom`.
// What is said in a room, and each person's pencil, are in LiveMessages.swift; here is how a
// room is keyed and sealed, its frames, glimpses of pictures, winks and the flight of a view.

// MARK: - Keys

/// Everything a shared design's room needs, made from its secret: the 32 random bytes in the
/// design's link, or for a design kept in a synced folder, in its `sharing/room.json`. Only those
/// it is shared with know the secret. The relay is given the room's id and its tokens, from which
/// neither the secret nor the key can be worked out. See Relay/SHARING.md.
nonisolated struct ShareKeys: Sendable, Equatable {
    let secret: Data
    /// The room's id on the relay: 64 hex digits.
    let room: String
    /// What reading from the room takes, and writing to it.
    let readToken: String
    let writeToken: String
    private let sealKey: SymmetricKey
    private let namesKey: SymmetricKey
    /// This launch's salt, which everything it seals carries, and the key made from it: each copy
    /// seals with a key of its own, so that no key is used for more than a little.
    private let salt: Data
    private let sessionKey: SymmetricKey

    init?(secret: Data) {
        guard secret.count == 32 else { return nil }
        self.secret = secret
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data("bezzle-share-2".utf8), info: Data(info.utf8), outputByteCount: 32)
        }
        room = derive("room").withUnsafeBytes { Data($0) }.hex
        readToken = derive("read").withUnsafeBytes { Data($0) }.base64URL
        writeToken = derive("write").withUnsafeBytes { Data($0) }.base64URL
        sealKey = derive("seal")
        namesKey = derive("names")
        var random = SystemRandomNumberGenerator()
        salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        sessionKey = Self.subkey(sealKey, salt)
    }

    /// The keys from a link's secret, as base64url.
    init?(link secret: String) {
        guard let data = Data(base64URL: secret) else { return nil }
        self.init(secret: data)
    }

    /// 32 new random bytes, a secret no room has had.
    static func newSecret() -> Data {
        var random = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
    }

    static func == (a: ShareKeys, b: ShareKeys) -> Bool { a.room == b.room }

    private static func subkey(_ key: SymmetricKey, _ salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: Data("bezzle-seal-2".utf8), outputByteCount: 32)
    }

    /// The name a picture goes by in the room, which tells the relay nothing of it.
    func pictureName(_ name: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(name.utf8), using: namesKey)).hex
    }

    /// `plain`, sealed so that only those with the secret can open it, and none can change it or
    /// pass it off as something else (`about`, the record's key or "live") unseen.
    func seal(_ plain: Data, about: String) -> Data? {
        guard let box = try? AES.GCM.seal(plain, using: sessionKey, authenticating: Data("\(room)/\(about)".utf8)),
              let combined = box.combined else { return nil }
        return Data([0x02]) + salt + combined
    }

    func open(_ sealed: Data, about: String) -> Data? {
        let bytes = [UInt8](sealed)
        guard bytes.count >= 1 + 16 + 12 + 16, bytes[0] == 0x02 else { return nil }
        let saltOf = Data(bytes[1..<17])
        let key = saltOf == salt ? sessionKey : Self.subkey(sealKey, saltOf)
        guard let box = try? AES.GCM.SealedBox(combined: Data(bytes[17...])) else { return nil }
        return try? AES.GCM.open(box, using: key, authenticating: Data("\(room)/\(about)".utf8))
    }
}

/// A shared design's live room: what it is called on the relay, and how what is said in it is
/// sealed. It is the room of the design's share, or of the synced folder it is kept in.
nonisolated struct LiveKey: Sendable, Equatable {
    let keys: ShareKeys
    var room: String { keys.room }

    init(_ keys: ShareKeys) { self.keys = keys }

    /// A message sealed so that only the room's own can open it, and none can change it unseen.
    func seal(_ message: LiveMessage) -> Data? {
        guard let plain = message.packed() else { return nil }
        return keys.seal(plain, about: "live")
    }

    func open(_ sealed: Data) -> LiveMessage? {
        guard let plain = keys.open(sealed, about: "live") else { return nil }
        return LiveMessage(packed: plain)
    }
}

nonisolated extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL text: String) {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var plain = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while plain.count % 4 != 0 { plain += "=" }
        self.init(base64Encoded: plain)
    }

    init?(hex text: String) {
        guard text.count % 2 == 0, text.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = []
        var i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: 2)
            guard let byte = UInt8(text[i..<j], radix: 16) else { return nil }
            bytes.append(byte)
            i = j
        }
        self.init(bytes)
    }
}

// MARK: - Frames

/// What goes to and comes from the relay around the sealed messages (see Relay/src/worker.js).
nonisolated enum LiveFrame: Equatable, Sendable {
    /// Joined: who this Mac is in the room, and who else is there.
    case welcome(you: UInt32, others: [UInt32])
    case joined(UInt32)
    case left(UInt32)
    case message(from: UInt32, Data)
    /// The room's records go up to this now: what is new is to be fetched.
    case records(UInt64)
    /// The room's owner stopped sharing it.
    case gone

    static func read(_ data: Data) -> LiveFrame? {
        let b = [UInt8](data)
        func u32(_ at: Int) -> UInt32 { b[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        guard let kind = b.first else { return nil }
        switch kind {
        case 0x01:
            guard b.count >= 7 else { return nil }
            let count = Int(b[5]) << 8 | Int(b[6])
            guard b.count >= 7 + count * 4 else { return nil }
            return .welcome(you: u32(1), others: (0..<count).map { u32(7 + $0 * 4) })
        case 0x02 where b.count >= 5: return .joined(u32(1))
        case 0x03 where b.count >= 5: return .left(u32(1))
        case 0x04 where b.count >= 5: return .message(from: u32(1), Data(b[5...]))
        case 0x05 where b.count >= 9: return .records(b[1..<9].reduce(0) { $0 << 8 | UInt64($1) })
        case 0x06: return .gone
        default: return nil
        }
    }

    /// A sealed message for everyone else in the room.
    static func toAll(_ sealed: Data) -> Data { Data([0x10]) + sealed }

    /// A sealed message for one of them.
    static func to(_ peer: UInt32, _ sealed: Data) -> Data {
        Data([0x11, UInt8(peer >> 24), UInt8(peer >> 16 & 0xFF), UInt8(peer >> 8 & 0xFF), UInt8(peer & 0xFF)]) + sealed
    }
}

// MARK: - Glimpses

/// Making a glimpse of a picture, and the picture that stands in from one (`LiveGlimpse`, with
/// the messages in LiveMessages.swift).
nonisolated extension LiveGlimpse {
    /// A glimpse of the picture in the file at `url`.
    static func of(_ url: URL, name: String) -> LiveGlimpse? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: pixels]
        guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, small, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(out) else { return nil }
        return LiveGlimpse(name: name, jpeg: data as Data)
    }

    // Core Image contexts may be used from any thread.
    nonisolated(unsafe) private static let context = CIContext(options: [.cacheIntermediates: false])

    /// The glimpse as it stands in for the picture: grown, and blurred smooth, as through frosted
    /// glass, so that its few pixels never show as squares.
    func standIn() -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let small = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let longest = CGFloat(max(small.width, small.height))
        guard longest > 0 else { return nil }
        let scale = 320 / longest
        let image = CIImage(cgImage: small)
        let extent = image.extent.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
        let grown = image.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingGaussianBlur(sigma: Double(scale) * 1.1)
            .cropped(to: extent)
        return Self.context.createCGImage(grown, from: extent)
    }
}

// MARK: - Winking

/// Tells a shake of the pointer, as people do to say "look here": the pointer going back and forth
/// quickly, four times or more, each way far enough to be meant.
nonisolated struct WinkDetector: Sendable {
    private var samples: [(p: CGPoint, t: Double)] = []
    private var lastWink = -Double.infinity

    static let window = 0.7
    static let reach: CGFloat = 16
    static let turnsNeeded = 4

    /// Takes a pointer position, in screen points, and returns whether a shake has just finished.
    mutating func add(_ p: CGPoint, at t: Double) -> Bool {
        samples.append((p, t))
        samples.removeAll { t - $0.t > Self.window }
        guard t - lastWink > 1.2, samples.count >= 6 else { return false }
        if turns(\.x) >= Self.turnsNeeded || turns(\.y) >= Self.turnsNeeded {
            lastWink = t
            samples.removeAll()
            return true
        }
        return false
    }

    /// How often the pointer turned back along one axis, counting only runs long enough.
    private func turns(_ axis: KeyPath<CGPoint, CGFloat>) -> Int {
        var count = 0
        var direction: CGFloat = 0
        var anchor = samples[0].p[keyPath: axis]
        var extreme = anchor
        for s in samples.dropFirst() {
            let v = s.p[keyPath: axis]
            if direction == 0 {
                if abs(v - anchor) >= Self.reach { direction = v > anchor ? 1 : -1; extreme = v }
            } else if (v - extreme) * direction > 0 {
                extreme = v
            } else if abs(extreme - v) >= Self.reach {
                count += 1
                direction = -direction
                anchor = extreme
                extreme = v
            }
        }
        return count
    }
}

// MARK: - Flying the view

/// The way from one view of the canvas to another that feels shortest: out, across and in again,
/// as van Wijk and Nuij worked out ("Smooth and efficient zooming and panning", 2003). Near views
/// glide; far ones lift off, so that both ends are in sight on the way.
nonisolated struct CameraFlight: Sendable {
    /// A view as its centre and how wide it is, in canvas points.
    struct Shot: Equatable, Sendable {
        var center: CGPoint
        var width: CGFloat
    }

    let from: Shot
    let to: Shot
    /// How far it goes, in the path's own measure, which the flight's time follows.
    let length: Double
    private static let rho = 1.42
    private var rho: Double { Self.rho }
    private let r0: Double
    private let u1: Double
    private let straight: Bool

    init(from: Shot, to: Shot) {
        self.from = from
        self.to = to
        let w0 = Double(max(from.width, 1e-6)), w1 = Double(max(to.width, 1e-6))
        let u = Double(hypot(to.center.x - from.center.x, to.center.y - from.center.y))
        let rho = Self.rho, rho2 = rho * rho
        u1 = u
        if u < 1e-6 * max(w0, w1) {
            straight = true
            r0 = 0
            length = abs(log(w1 / w0)) / rho
        } else {
            straight = false
            func r(_ i: Int) -> Double {
                let w = i == 0 ? w0 : w1
                let b = (w1 * w1 - w0 * w0 + (i == 0 ? 1 : -1) * rho2 * rho2 * u * u) / (2 * w * rho2 * u)
                return log(-b + (b * b + 1).squareRoot())
            }
            let start = r(0)
            r0 = start
            length = (r(1) - start) / rho
        }
    }

    /// How long it takes: longer the further it goes, never so long it drags.
    var duration: Double { min(max(length * 0.42, 0.45), 1.5) }

    /// Where it is a fraction `f` of the way, eased to leave and arrive gently.
    func shot(at f: Double) -> Shot {
        let f = min(max(f, 0), 1)
        let eased = f * f * (3 - 2 * f)
        let s = eased * length
        let w0 = Double(from.width)
        if straight {
            let k = to.width >= from.width ? 1.0 : -1.0
            let w = length == 0 ? w0 + (Double(to.width) - w0) * eased : w0 * exp(k * rho * s)
            return Shot(center: mix(from.center, to.center, eased), width: CGFloat(w))
        }
        let rho2 = rho * rho
        let u = w0 / rho2 * cosh(r0) * tanh(rho * s + r0) - w0 / rho2 * sinh(r0)
        let w = w0 * cosh(r0) / cosh(rho * s + r0)
        return Shot(center: mix(from.center, to.center, u / u1), width: CGFloat(w))
    }

    private func mix(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}

extension Viewport {
    /// The view as a camera shot, in a canvas of `size`.
    func shot(in size: CGSize) -> CameraFlight.Shot {
        CameraFlight.Shot(center: CGPoint(x: origin.x + size.width / 2 / zoom, y: origin.y + size.height / 2 / zoom), width: size.width / zoom)
    }

    /// The view a shot is, in a canvas of `size`.
    init(_ shot: CameraFlight.Shot, in size: CGSize) {
        let zoom = min(max(size.width / max(shot.width, 1e-6), Viewport.minZoom), Viewport.maxZoom)
        self.init(origin: CGPoint(x: shot.center.x - size.width / 2 / zoom, y: shot.center.y - size.height / 2 / zoom), zoom: zoom)
    }

    /// The view that shows `rect` (what someone else's canvas shows) in a canvas of `size`: all of
    /// it, about its middle.
    init(showing rect: CGRect, in size: CGSize) {
        let zoom = min(max(min(size.width / max(rect.width, 1), size.height / max(rect.height, 1)), Viewport.minZoom), Viewport.maxZoom)
        self.init(origin: CGPoint(x: rect.midX - size.width / 2 / zoom, y: rect.midY - size.height / 2 / zoom), zoom: zoom)
    }
}

extension SharedDesign {
    /// Who made the latest change to each layer here, by their replica.
    nonisolated var authors: [UUID: String] {
        var out: [UUID: String] = [:]
        for (id, layer) in layers {
            let latest = ([layer.place?.stamp].compactMap { $0 } + layer.fields.values.map(\.stamp)).max()
            if let latest { out[id] = latest.by }
        }
        return out
    }
}
