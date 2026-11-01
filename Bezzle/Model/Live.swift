import Foundation
import CoreGraphics
import CoreImage
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// Working on a shared design at the same moment: everyone's hand, gaze and changes as they
// happen, passed between the Macs that have it open by a relay that cannot read them. iCloud
// keeps the design; this only makes it quick. See `LiveRoom`.

// MARK: - Keys

/// What a shared design's live room is called, and the key everything in it is sealed with. Both
/// come from the design's zone in iCloud, which only those it is shared with know; the relay sees
/// the room's name alone, from which neither the key nor the zone can be worked out.
nonisolated struct LiveKey: Sendable, Equatable {
    let room: String
    let key: SymmetricKey

    init(zone: String) {
        let material = SymmetricKey(data: Data(zone.utf8))
        let salt = Data("bezzle-live-1".utf8)
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: salt, info: Data("seal".utf8), outputByteCount: 32)
        let name = HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: salt, info: Data("room".utf8), outputByteCount: 32)
        room = name.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    }

    static func == (a: LiveKey, b: LiveKey) -> Bool { a.room == b.room }

    /// A message sealed so that only the room's own can open it, and none can change it unseen.
    func seal(_ message: LiveMessage) -> Data? {
        guard var data = try? JSONEncoder().encode(message) else { return nil }
        var packed: UInt8 = 0
        if data.count > 1500, let small = try? (data as NSData).compressed(using: .lzfse) as Data, small.count < data.count {
            data = small
            packed = 1
        }
        return try? ChaChaPoly.seal(Data([packed]) + data, using: key).combined
    }

    func open(_ sealed: Data) -> LiveMessage? {
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed),
              let plain = try? ChaChaPoly.open(box, using: key), let flag = plain.first else { return nil }
        var data = plain.dropFirst()
        if flag == 1 {
            guard let wide = try? (Data(data) as NSData).decompressed(using: .lzfse) as Data else { return nil }
            data = wide[...]
        }
        return try? JSONDecoder().decode(LiveMessage.self, from: Data(data))
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

// MARK: - Messages

/// Who someone is, said on coming in and to each who comes after.
nonisolated struct LiveHello: Codable, Equatable, Sendable {
    /// Their Mac's name among those sharing the design (`CloudSync.replica`), which their changes carry.
    var replica: String
    var name: String
    /// Where they are in the world, to say what time it is for them.
    var timeZone: String?
    /// Set when saying who one is to someone heard from but not known: they say who they are back.
    var ask: Bool?
}

/// Where someone is and what they are doing, sent whenever it changes, a few dozen times a second
/// at most, and every few seconds to say they are still there.
nonisolated struct LivePresence: Codable, Equatable, Sendable {
    /// Their pointer on the canvas, in canvas points; none while it is off the canvas.
    var pointer: CGPoint?
    /// What their canvas shows, in canvas points.
    var view: CGRect
    var selection: [UUID] = []
    var tool: String = "select"
    var doing: Doing = .looking
    /// In another app, or in another window.
    var away = false

    enum Doing: String, Codable, Sendable {
        case looking, moving, typing, drawing
    }

    enum CodingKeys: String, CodingKey { case pointer = "p", view = "v", selection = "s", tool = "t", doing = "d", away = "a" }
}

nonisolated enum LiveMessage: Codable, Equatable, Sendable {
    case hello(LiveHello)
    case presence(LivePresence)
    /// The layers someone is dragging or changing, as they are this moment, without what they
    /// hold: shown moving here before the change is made.
    case motion([Node])
    /// Their drag ended, with the layers as it left them, for the motion to settle on.
    case settle([Node])
    /// Changes made, exactly as iCloud carries them, merged the same way (see `SharedDesign`).
    case changes(SharedDesign)
    /// They shook their pointer here, to be looked at.
    case wink(CGPoint)
    /// Glimpses of pictures they have and others may not yet, to show until those come.
    case glimpses([LiveGlimpse])
    /// Pictures this Mac shows but does not have: whoever has them sends glimpses.
    case want([String])
    /// A version someone named, with the design as it was then, packed, when small enough to
    /// come this way; otherwise it comes through iCloud.
    case version(DesignVersion, Data?)
}

// MARK: - Glimpses

/// A picture seen from afar: the same picture a few dozen pixels across, about a kilobyte, sent
/// the moment it is placed so that others see what is coming long before iCloud brings the
/// picture itself. Shown soft and blurred, it develops into the picture as that arrives.
nonisolated struct LiveGlimpse: Codable, Equatable, Sendable {
    var name: String
    var jpeg: Data

    static let pixels = 32

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

// MARK: - Coloured pencils

/// Everyone's own colour. Bezzle marks your work up in blue pencil; each other person draws in a
/// pencil of their own, the same one on every Mac in the room.
nonisolated enum Pencil: Int, CaseIterable, Sendable {
    case vermilion, ochre, viridian, rose, teal, sepia, olive, plum

    /// As sRGB, reading on white artboards and on the dark table alike.
    var rgb: (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch self {
        case .vermilion: (0.882, 0.298, 0.188)
        case .ochre: (0.851, 0.584, 0.106)
        case .viridian: (0.106, 0.612, 0.459)
        case .rose: (0.851, 0.263, 0.494)
        case .teal: (0.078, 0.580, 0.702)
        case .sepia: (0.651, 0.400, 0.235)
        case .olive: (0.420, 0.600, 0.157)
        case .plum: (0.616, 0.247, 0.651)
        }
    }

    var cgColor: CGColor { CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1) }
    func cgColor(_ alpha: CGFloat) -> CGColor { CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha) }

    /// The pencil a person would rather have, the same on every Mac.
    static func preferred(_ replica: String) -> Pencil {
        let hash = SHA256.hash(data: Data(replica.utf8)).prefix(4).reduce(0) { $0 << 8 | Int($1) }
        return allCases[hash % allCases.count]
    }

    /// A pencil for each of the people in a room, no two the same while there are enough: in the
    /// order of their names, each gets the one they would rather have, or the next free one. Every
    /// Mac that knows the same people hands out the same pencils.
    static func hand(to replicas: Set<String>) -> [String: Pencil] {
        var out: [String: Pencil] = [:]
        var taken = Set<Pencil>()
        for replica in replicas.sorted() {
            var p = preferred(replica)
            if taken.count < allCases.count {
                while taken.contains(p) { p = allCases[(p.rawValue + 1) % allCases.count] }
            }
            taken.insert(p)
            out[replica] = p
        }
        return out
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

// MARK: - Circling

/// The loop a hand draws round something to say "look here", as on a printout: a little wider
/// than high, tilted, never quite round, its end running on past its start. Each is drawn a
/// little differently, from its seed. Points around nothing, for a loop `radius` across.
nonisolated enum PencilLoop {
    static let samples = 72

    static func points(seed: UInt64, radius: CGFloat) -> [CGPoint] {
        var s = seed &* 0x9E37_79B9_7F4A_7C15
        func random() -> Double {
            s ^= s >> 12; s ^= s << 25; s ^= s >> 27
            return Double((s &* 0x2545_F491_4F6C_DD1D) >> 11) / Double(1 << 53)
        }
        let start = -2.3 + random() * 0.6
        let tilt = -0.28 + random() * 0.22
        let sweep = 2 * Double.pi + 0.55 + random() * 0.35
        let p1 = random() * 6.28, p2 = random() * 6.28
        let rx = Double(radius) * 1.16, ry = Double(radius) * 0.84
        return (0...samples).map { i in
            let f = Double(i) / Double(samples)
            let a = start + sweep * f
            // Wavering as a hand does, and opening out a little as it comes round again.
            let wobble = 1 + 0.045 * sin(1.7 * a + p1) + 0.025 * sin(3.3 * a + p2) + 0.09 * f * f
            let x = cos(a) * rx * wobble, y = sin(a) * ry * wobble
            return CGPoint(x: x * cos(tilt) - y * sin(tilt), y: x * sin(tilt) + y * cos(tilt))
        }
    }

    /// How wide the line is a fraction `f` along it: fine where the pencil lands and lifts.
    static func width(at f: Double, _ full: CGFloat) -> CGFloat {
        full * CGFloat(0.3 + 0.7 * pow(sin(Double.pi * min(max(f, 0), 1)), 0.55))
    }

    /// How far along it is drawn `t` seconds in, quick as a hand is, and how strong it shows.
    static func shown(at t: Double) -> (drawn: Double, alpha: Double) {
        let drawn = t <= 0 ? 0 : t >= 0.52 ? 1 : 1 - pow(1 - t / 0.52, 2.2)
        let alpha = t < 1.7 ? 1 : max(0, 1 - (t - 1.7) / 0.55)
        return (drawn, alpha)
    }

    static let lasts = 2.3
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
