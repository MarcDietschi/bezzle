import Foundation
import CoreGraphics
import CryptoKit

// What is said in a live room (see Live.swift, which seals it, and `LiveRoom`): who someone is,
// where they are and what they hold, what they drag and change. And what everyone in a room works
// out alike from it: each person's coloured pencil, and the loop a pencil draws round something.
// Apart from Live.swift so that the browser's viewer, which seals with the browser's own
// cryptography and only watches, reads the same messages with the same code (Web/).

// MARK: - Messages

/// Who someone is, said on coming in and to each who comes after.
nonisolated struct LiveHello: Codable, Equatable, Sendable {
    /// Their Mac's name among those sharing the design (`Sharing.replica`), which their changes carry.
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

nonisolated extension LiveMessage {
    /// As it travels inside its seal: a byte that says whether what follows is packed (LZFSE,
    /// where that makes a long message shorter), then its JSON.
    func packed() -> Data? {
        guard var data = try? JSONEncoder().encode(self) else { return nil }
        var packed: UInt8 = 0
        if data.count > 1500, let small = try? (data as NSData).compressed(using: .lzfse) as Data, small.count < data.count {
            data = small
            packed = 1
        }
        return Data([packed]) + data
    }

    /// The message that travelled as `plain`; nil when that is none.
    init?(packed plain: Data) {
        guard let flag = plain.first else { return nil }
        var data = plain.dropFirst()
        if flag == 1 {
            guard let wide = try? (Data(data) as NSData).decompressed(using: .lzfse) as Data else { return nil }
            data = wide[...]
        }
        guard let message = try? JSONDecoder().decode(LiveMessage.self, from: Data(data)) else { return nil }
        self = message
    }
}

// MARK: - Glimpses

/// A picture seen from afar: the same picture a few dozen pixels across, about a kilobyte, sent
/// the moment it is placed so that others see what is coming long before iCloud brings the
/// picture itself. Shown soft and blurred, it develops into the picture as that arrives.
nonisolated struct LiveGlimpse: Codable, Equatable, Sendable {
    var name: String
    var jpeg: Data

    static let pixels = 32
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
        // Four bytes as a number of 32 bits, for the browser's core too, whose `Int` holds no more.
        let hash = SHA256.hash(data: Data(replica.utf8)).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return allCases[Int(hash % UInt32(allCases.count))]
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
            // 2 to the 53rd as a number of 64 bits: the browser's core has an `Int` of 32.
            return Double((s &* 0x2545_F491_4F6C_DD1D) >> 11) / Double(UInt64(1) << 53)
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
