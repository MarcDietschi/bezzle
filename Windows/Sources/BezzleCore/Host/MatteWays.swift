import Foundation

// From Bezzle/Canvas/SubjectMatte.swift (Grade, Route) and Bezzle/Store/SubjectModel.swift (which way
// a computer takes, and what it remembers of each): how finely a picture is cut out, the ways a
// matte is made, which of them a PC takes for a picture, and what is kept of them from one run of
// Bezzle to the next. Nothing here asks Windows anything, nor runs the model: what the PC is like
// is handed in (`MatteMachine`), and Host/SubjectMatte.swift asks Windows and runs the model. So
// the ways are the same wherever this is compiled, and Windows/Tests checks them on a Mac too.
//
// Keep the names in step with the Mac's (the ways' descriptions, the grades, the cutouts' names,
// the settings' keys): a design shared between a Mac and a PC finds on each the cutouts the other
// made, and never takes a plainer one for a finer one.

/// How finely a picture was cut out: what its cutout is named for, so a finer one is never passed
/// over for a plainer one made on another computer. The Mac's `SubjectMatte.Grade`.
nonisolated enum MatteGrade: Int, Comparable, CaseIterable, Sendable {
    /// Without the model: a Mac's older way. Bezzle for Windows makes none such, and shows one a Mac made.
    case plain
    /// The model at 1,024 pixels.
    case light
    /// The model at 2,048 pixels.
    case fine

    static func < (a: MatteGrade, b: MatteGrade) -> Bool { a.rawValue < b.rawValue }
}

/// One way of making a matte: the size the model sees the picture at, squeezed square, and where
/// it runs, on the graphics card (through DirectML) or on the processor. The Mac's `SubjectMatte.Route`.
nonisolated struct MatteRoute: Hashable, Sendable, CustomStringConvertible {
    var side: Int
    var onCard: Bool

    static let fineOnCard = MatteRoute(side: 2048, onCard: true), fine = MatteRoute(side: 2048, onCard: false)
    static let lightOnCard = MatteRoute(side: 1024, onCard: true), light = MatteRoute(side: 1024, onCard: false)
    static let all = [fineOnCard, fine, lightOnCard, light]

    /// What it is called where it is remembered, and for trying one alone (BEZZLE_MATTE_ROUTE):
    /// the Mac's names.
    var description: String { "\(onCard ? "gpu" : "cpu")\(side)" }
    var grade: MatteGrade { side >= 2048 ? .fine : .light }
    /// The model's graph for this size, in Bezzle.resources: both read BiRefNet.weights beside them.
    var graph: String { "BiRefNet-\(side).onnx" }

    /// The memory it holds while it runs, in bytes. On the processor as measured in the test VM
    /// (Windows 11 for Arm, 8 cores, 12 GB; 2026-11-10): Bezzle's whole working set at its peak,
    /// about 2 GB at either size, as ONNX Runtime uses what one layer leaves for the next. On the
    /// card guesses from what the Mac's GPU holds, until measured on a real one. Only their order
    /// is used, to tell which of two ways asked the most of the PC.
    var holds: UInt64 {
        let megabytes: UInt64 = switch (side >= 2048, onCard) {
        case (true, true): 9_000
        case (true, false): 2_000
        case (false, true): 3_000
        case (false, false): 1_900
        }
        return megabytes * 1_000_000
    }

    /// How many seconds loading the model and making a matte take on a PC nothing is known of
    /// yet, with so many fast `cores`. The processor's from ONNX Runtime on a Mac of 18 cores (5 s
    /// at 1,024 pixels, 21 to 23 s at 2,048), longer the fewer cores there are, which the test VM
    /// of 8 cores bears out (10 to 11 s and 43 to 54 s; loading 1.3 s). The card's are guesses
    /// until measured on a real one, DirectML fitting the model to the card as it loads.
    func first(cores: Int) -> (load: Double, matte: Double) {
        let slower = 18 / Double(max(cores, 1))
        return switch (side >= 2048, onCard) {
        case (true, true): (12, 5)
        case (true, false): (2, 23 * slower)
        case (false, true): (8, 2)
        case (false, false): (2, 5 * slower)
        }
    }
}

/// What of a PC decides how it makes a matte. The Mac's `SubjectModel.Machine`.
nonisolated struct MatteMachine: Sendable, Equatable {
    /// Its memory, in bytes.
    var memory: UInt64
    /// Its processor's cores, but for the efficiency cores.
    var cores: Int
    /// The memory its graphics card has of its own, in bytes. None where the graphics share the
    /// PC's memory (integrated), are Windows' own on the processor, or do not run Direct3D 12.
    var dedicated: UInt64 = 0
}

nonisolated extension MatteMachine {
    static let gigabyte = 1_073_741_824.0

    /// The PC BEZZLE_MATTE_MACHINE describes, for trying another's ways here: gigabytes of memory,
    /// fast cores and, with a graphics card, the gigabytes of its own, as "16:8" or "32:12:8".
    init?(describing said: String) {
        let parts = said.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, let memory = Double(parts[0]), let cores = Int(parts[1]), memory > 0, cores > 0 else { return nil }
        var dedicated = 0.0
        if parts.count == 3 {
            guard let card = Double(parts[2]), card >= 0 else { return nil }
            dedicated = card
        }
        self.init(memory: UInt64(memory * Self.gigabyte), cores: cores, dedicated: UInt64(dedicated * Self.gigabyte))
    }
}

/// Which ways a PC takes. The Mac's `SubjectModel.routes`, with a PC's measures.
nonisolated enum MatteWays {
    /// Which model this is: the Mac's (`SubjectMatte.version` there), as it is the same model.
    /// Cutouts made with it are named for it, so a new one cuts pictures out afresh.
    static let version = 1

    /// A picture this many pixels along its longer side, as it is worked on, has something for
    /// the fine size to find. A smaller one would only be blown up for it, and the light size
    /// finds as much in it, in a quarter of the memory and the time.
    static let fineFrom = 1536

    /// A way that took longer than this many seconds is passed over the next time.
    static let patience = 25.0

    // What a PC needs for each way. The card's are estimates until measured on real PCs: so far
    // the model has run through DirectML on none. Each is a little under the round number a PC is
    // sold with, as Windows counts less than that (what the firmware and the graphics keep).

    /// Gigabytes of its own a graphics card needs for the fine size (a card sold with 12).
    static let cardForFine = 11.5
    /// Gigabytes of its own a graphics card needs for the light size (a card sold with 6).
    static let cardForLight = 5.5
    /// Gigabytes of memory below which the card is left alone: DirectML keeps as much of the
    /// model in the PC's memory as on the card (a PC sold with 8).
    static let memoryForCard = 7.5
    /// Gigabytes of memory, and fast cores, the fine size on the processor needs. Time is what it
    /// asks: 2 GB while it runs, as the light size, but four times as long, 45 s and more with 8
    /// cores (the test VM) and about 25 s with 16, which is as long as anyone waits (`patience`).
    /// So only a processor of 16 fast cores takes it, in a PC sold with 16 GB at least.
    static let memoryForFine = 15.5
    static let coresForFine = 16
    /// Memory is short while this share of it is in use, in percent, or fewer than this many
    /// bytes are left to hand out: the card is left alone then, and a model kept is let go.
    static let shortLoad = 90
    static let shortAvailable: UInt64 = 1_610_612_736

    /// Whether memory is short, by what Windows says of it: the share in use, in percent, and
    /// the bytes it can still hand out.
    static func memoryIsShort(load: Int, available: UInt64) -> Bool {
        load >= shortLoad || available < shortAvailable
    }

    /// The ways `machine` makes a matte of a picture `longest` pixels along its longer side, the
    /// one to take first, and after each the one to take should it fail. The last is always the
    /// light size on the processor, which every PC can afford: Windows has no way without the model.
    ///
    /// A graphics card with memory of its own is far the fastest: with 12 GB the fine size for a
    /// large picture, with 6 GB the light size. Integrated graphics and smaller cards are left
    /// alone, and the processor makes the matte: at the fine size only for a large picture on a
    /// PC with 16 fast cores, at the light size on all the others.
    static func routes(longest: Int, on machine: MatteMachine) -> [MatteRoute] {
        let memory = Double(machine.memory) / MatteMachine.gigabyte, card = Double(machine.dedicated) / MatteMachine.gigabyte
        let large = longest >= fineFrom
        var ways: [MatteRoute] = []
        if memory >= memoryForCard {
            if card >= cardForFine {
                ways = large ? [.fineOnCard, .lightOnCard] : [.lightOnCard]
            } else if card >= cardForLight {
                ways = [.lightOnCard]
            }
        }
        if ways.isEmpty, large, memory >= memoryForFine, machine.cores >= coresForFine { ways = [.fine] }
        return ways + [.light]
    }
}

/// What Bezzle remembers of the ways from one run to the next, in its settings: which was running
/// (so that one that took Bezzle down is known the next time, and passed over), and how long each
/// took here. The Mac's `SubjectModel` keeps the same under the same names.
nonisolated final class MatteLedger: @unchecked Sendable {
    let machine: MatteMachine
    private let defaults: UserDefaults
    private let version: String
    /// The one way to take, whatever the PC (BEZZLE_MATTE_ROUTE), for trying it.
    private let forced: String?
    private let lock = NSLock()
    /// The ways running just now, as `Key.running` says on disk.
    private var running: Set<MatteRoute> = []
    /// The way Bezzle went down with the last time, found as this began: passed over from now on.
    let wentDownWith: MatteRoute?

    private enum Key {
        static let running = "subjectMatte.running", avoided = "subjectMatte.avoided"
        static func seconds(_ route: MatteRoute, cold: Bool) -> String { "subjectMatte.seconds.\(route).\(cold ? "cold" : "warm")" }
        static func loading(_ route: MatteRoute) -> String { "subjectMatte.loading.\(route)" }
    }

    /// `version` is Bezzle's: a way passed over is tried again by the next version.
    init(machine: MatteMachine, defaults: UserDefaults = .standard, version: String, forced: String? = nil) {
        self.machine = machine
        self.defaults = defaults
        self.version = version
        self.forced = forced
        // A way still marked as running was running when Bezzle went down: not taken again by
        // this version of Bezzle. Of several, the one that asks the most of the PC. Never the
        // lightest way: there is none after it.
        let names = defaults.stringArray(forKey: Key.running) ?? []
        let heaviest = MatteRoute.all.filter { names.contains("\($0)") && $0 != .light }.max { $0.holds < $1.holds }
        if let heaviest {
            var avoided = defaults.dictionary(forKey: Key.avoided) as? [String: String] ?? [:]
            avoided["\(heaviest)"] = version
            defaults.set(avoided, forKey: Key.avoided)
        }
        wentDownWith = heaviest
        if !names.isEmpty {
            defaults.removeObject(forKey: Key.running)
            _ = defaults.synchronize()
        }
    }

    /// The ways to make a matte of a picture `longest` pixels long here and now, the first to
    /// take first: this PC's, without those that took Bezzle down or took too long, without the
    /// card while memory is `short`, and without the fine size where its graph is not there
    /// (`fine`). The lightest way is never passed over.
    func ways(longest: Int, short: Bool = false, fine: Bool = true) -> [MatteRoute] {
        if let forced { return MatteRoute.all.filter { $0.description == forced } }
        let avoided = defaults.dictionary(forKey: Key.avoided) as? [String: String] ?? [:]
        return MatteWays.routes(longest: longest, on: machine).filter { route in
            if route == .light { return true }
            if route.grade == .fine && !fine { return false }
            if route.onCard && short { return false }
            if avoided["\(route)"] == version { return false }
            return took(route) <= MatteWays.patience
        }
    }

    /// How long a matte took by `route` here, the longer of its first after loading and those
    /// after it; nothing if it never made one.
    func took(_ route: MatteRoute) -> Double {
        max(defaults.double(forKey: Key.seconds(route, cold: false)), defaults.double(forKey: Key.seconds(route, cold: true)))
    }

    /// Says on disk whether `route` is running, so that Bezzle, started again after going down
    /// with it, knows. Written out at once: there may be no later.
    func mark(_ route: MatteRoute, running on: Bool) {
        let names = lock.withLock { () -> [String] in
            if on { running.insert(route) } else { running.remove(route) }
            return running.map(\.description).sorted()
        }
        if names.isEmpty { defaults.removeObject(forKey: Key.running) } else { defaults.set(names, forKey: Key.running) }
        _ = defaults.synchronize()
    }

    /// Bezzle is quitting: a matte cut short by that is no matte that took Bezzle down.
    func quitting() {
        lock.withLock { running.removeAll() }
        defaults.removeObject(forKey: Key.running)
        _ = defaults.synchronize()
    }

    /// How long loading the model and making the matte are expected to take by `route`: as long
    /// as they took here before, or by what is known of this PC. `loading` when the model is not
    /// loaded yet; `cold` when the matte is the model's first since it was.
    func expecting(_ route: MatteRoute, loading: Bool, cold: Bool) -> [CutoutPace.Step: Double] {
        let first = route.first(cores: machine.cores)
        let load = defaults.double(forKey: Key.loading(route))
        var matte = defaults.double(forKey: Key.seconds(route, cold: cold))
        if matte <= 0 { matte = defaults.double(forKey: Key.seconds(route, cold: !cold)) }
        return [.load: loading ? (load > 0 ? load : first.load) : 0, .matte: matte > 0 ? matte : first.matte]
    }

    /// A matte took `seconds` by `route`.
    func remember(matte seconds: Double, by route: MatteRoute, cold: Bool) { remember(seconds, for: Key.seconds(route, cold: cold)) }

    /// Loading the model for `route` took `seconds`.
    func remember(loading seconds: Double, for route: MatteRoute) { remember(seconds, for: Key.loading(route)) }

    /// How long something took, kept leaning to the last time over those before.
    private func remember(_ seconds: Double, for key: String) {
        let before = defaults.double(forKey: key)
        defaults.set(before > 0 ? before * 0.3 + seconds * 0.7 : seconds, forKey: key)
    }
}

/// How long reading a picture and finishing its cutout take, by how large it is: as long as they
/// took a megapixel here before, kept in the settings under the Mac's names.
nonisolated struct CutoutTimes {
    private let defaults: UserDefaults
    private static let reading = "cutout.reading", finishing = "cutout.finishing"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// How long reading (`look`) and finishing a picture of so many `megapixels` are expected to
    /// take. Estimates until it has cut one out: finishing is the longer here, as it finds the
    /// subject in the matte too, which Apple's Vision does for the Mac while it looks.
    func expecting(megapixels: Double) -> [CutoutPace.Step: Double] {
        let reading = defaults.double(forKey: Self.reading), finishing = defaults.double(forKey: Self.finishing)
        return [.look: 0.2 + megapixels * (reading > 0 ? reading : 0.03), .finish: 0.3 + megapixels * (finishing > 0 ? finishing : 0.2)]
    }

    /// Reading took `reading` seconds and finishing `finishing`, for a picture of so many `megapixels`.
    func remember(reading: Double?, finishing: Double?, megapixels: Double) {
        func remember(_ seconds: Double, _ key: String) {
            let before = defaults.double(forKey: key), now = max(0, seconds) / max(megapixels, 0.25)
            defaults.set(before > 0 ? (before + now) / 2 : now, forKey: key)
        }
        if let reading { remember(reading, Self.reading) }
        if let finishing { remember(finishing, Self.finishing) }
    }
}

/// The last pictures' mattes, by what the pictures are called: picking other subjects in a
/// picture just cut out asks the model nothing. A matte kept is taken only where it is at least
/// as fine as the one that would be made now.
nonisolated struct KeptMattes<Matte> {
    /// How many pictures' mattes are kept: each is as large as the model's square.
    static var most: Int { 3 }
    private var kept: [(key: String, grade: MatteGrade, matte: Matte)] = []

    init() {}

    /// The matte kept of the picture called `key`, if it is as fine as `wanted` or finer.
    func matte(of key: String, atLeast wanted: MatteGrade) -> (matte: Matte, grade: MatteGrade)? {
        guard let found = kept.first(where: { $0.key == key }), found.grade >= wanted else { return nil }
        return (found.matte, found.grade)
    }

    /// Keeps `matte` of the picture called `key` in place of any kept of it before; the oldest
    /// goes when there are more than `most`.
    mutating func keep(_ matte: Matte, of key: String, grade: MatteGrade) {
        kept.removeAll { $0.key == key }
        kept.append((key, grade, matte))
        if kept.count > Self.most { kept.removeFirst() }
    }

    mutating func forget() { kept.removeAll() }

    var count: Int { kept.count }
}

/// What cutouts are called beside their pictures: the Mac's `DocumentStore.cutoutName`, letter
/// for letter, so a cutout made on either is found by the other in a shared design.
nonisolated enum CutoutNames {
    /// What the cutout of the picture `asset` is called: the same each time it is cut out with
    /// the same picks, so taking the background away again finds it made, however often it was
    /// given back. It is named for how finely it was cut out: with the learned matte, for the
    /// model's version and, at the light size, for that, so a plainer cutout is never taken for a
    /// finer one.
    static func name(of asset: String, picks: [CGPoint]?, grade: MatteGrade) -> String {
        let made = switch grade {
        case .plain: "-cutout"
        case .light: "-cutout-m\(MatteWays.version)-1024"
        case .fine: "-cutout-m\(MatteWays.version)"
        }
        let stem = (asset as NSString).deletingPathExtension + made
        guard let picks, !picks.isEmpty else { return "\(stem).png" }
        // FNV-1a over the picks to a ten-thousandth, the same on every computer and every run.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in picks.map({ String(format: "%.4f,%.4f", Double($0.x), Double($0.y)) }).joined(separator: ";").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return "\(stem)-\(String(hash, radix: 16)).png"
    }

    /// The names a cutout of `asset` as fine as `wanted` or finer may have, the finest first.
    static func names(of asset: String, picks: [CGPoint]?, atLeast wanted: MatteGrade) -> [(grade: MatteGrade, name: String)] {
        MatteGrade.allCases.reversed().filter { $0 >= wanted }.map { ($0, name(of: asset, picks: picks, grade: $0)) }
    }
}
