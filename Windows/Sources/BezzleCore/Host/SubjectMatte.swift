import Foundation
import CBezzleHost

// From Bezzle/Canvas/SubjectMatte.swift and Store/SubjectModel.swift: the same model the Mac runs,
// BiRefNet_HR, as ONNX graphs of its two sizes, 2,048 and 1,024 pixels, that read the same weights
// (BiRefNet-2048.onnx, BiRefNet-1024.onnx and BiRefNet.weights, Scripts/subject-matte), run with
// ONNX Runtime (CBezzleHost/matte.cpp) on the graphics card through DirectML or on the processor.
// Which of the four ways a picture takes is the Mac's question with a PC's answers, and what is
// remembered of the ways is the Mac's (Host/MatteWays.swift, which asks Windows nothing and is
// tested apart). The weights are kept to 8 bits as the Mac's are, and every layer computes in full
// precision: in half precision whole parts of a picture were lost on Arm processors.

/// A learned matte of what stands out in a picture, hair by hair: BiRefNet (Peng Zheng et al.,
/// MIT licence), its high-resolution model, opened for one way of running it (`Route`).
/// `CutoutMaker` keeps it to the subject picked.
nonisolated final class SubjectMatte: CutoutMaker.Matting, @unchecked Sendable {
    /// Which model this is: the Mac's (`SubjectMatte.version` there), as it is the same model.
    /// Cutouts made with it are named for it (`cutoutName`), so a new one cuts pictures out afresh
    /// rather than finding the old one's, here and on a Mac sharing the design alike.
    static let version = MatteWays.version

    typealias Grade = MatteGrade
    typealias Route = MatteRoute

    /// The way it was opened for.
    let route: Route
    /// The side of the square the model sees a picture at, squeezed: the graph's own, where it
    /// says (a model BEZZLE_MATTE_MODEL names may be of another size than the way asks for).
    let side: Int
    /// How finely it cuts out, by that size.
    var grade: Grade { side >= 2048 ? .fine : .light }

    /// On the processor: opened for the lean way (`MatteWays.Fit`), which holds the least and
    /// takes the longest. The matte is the same either way.
    let lean: Bool

    private let handle: UnsafeMutableRawPointer
    /// Where it runs, in words: "DirectML on …", "processor" or "processor, the lean way".
    var device: String {
        var on = [CChar](repeating: 0, count: 512)
        _ = bz_matte_device(handle, &on, Int32(on.count))
        return String(cString: on)
    }

    /// The graph at `url`, made ready for `route`: on the processor, the `lean` way when asked,
    /// or on the graphics card and there alone (DirectML fits it to the card first, which takes
    /// seconds). A card that cannot hold it throws, here or at a matte: `SubjectModel` then takes
    /// a lighter way. With `anyAdapter`, on whatever adapter DirectML runs on, Windows' own on
    /// the processor too, for trying it where there is no card.
    init(contentsOf url: URL, route: Route, anyAdapter: Bool = false, lean: Bool = false) throws {
        var error = [CChar](repeating: 0, count: 1024), on = [CChar](repeating: 0, count: 512)
        let lean = lean && !route.onCard
        let device: Int32 = route.onCard ? (anyAdapter ? 2 : 3) : (lean ? 4 : 1)
        guard let made = bz_matte_open(url.path, device, &error, Int32(error.count), &on, Int32(on.count)) else {
            throw Trouble(description: String(cString: error))
        }
        handle = made
        self.route = route
        self.lean = lean
        let says = Int(bz_matte_side(made))
        side = says > 0 ? says : route.side
    }

    deinit { bz_matte_close(handle) }

    struct Trouble: Swift.Error, CustomStringConvertible { let description: String }

    /// How solid each pixel of `picture` is, `side` × `side`, for `CutoutMaker`.
    func matte(of picture: CutoutMaker.Pixels) throws -> CutoutMaker.Plane {
        let input = try Self.square(picture, side: side)
        let matte = CutoutMaker.Plane(side, side)
        var error = [CChar](repeating: 0, count: 1024)
        let done = input.withUnsafeBufferPointer { bz_matte_run(handle, $0.baseAddress, Int32(side), matte.p, &error, Int32(error.count)) }
        guard done == 0 else { throw Trouble(description: String(cString: error)) }
        return matte
    }

    /// `picture` squeezed into the square of `side` pixels the model sees, as the Mac's draws it:
    /// red, green and blue planes, 0…1, in sRGB whatever colours the picture is in.
    static func square(_ picture: CutoutMaker.Pixels, side: Int) throws -> [Float] {
        guard let square = (picture.w == side && picture.h == side ? picture : picture.scaled(side, side))?.inSRGB() else {
            throw CutoutMaker.Failure.unreadable
        }
        let n = side * side
        var planes = [Float](repeating: 0, count: 3 * n)
        square.bytes.withUnsafeBufferPointer { px in
            planes.withUnsafeMutableBufferPointer { out in
                let o = out.baseAddress!
                CutoutMaker.par(n) { r in
                    for i in r {
                        // Over white where it is see-through, as the Mac's context is filled first.
                        let white = Float(255 - px[i * 4 + 3])
                        o[i] = (Float(px[i * 4]) + white) / 255
                        o[n + i] = (Float(px[i * 4 + 1]) + white) / 255
                        o[2 * n + i] = (Float(px[i * 4 + 2]) + white) / 255
                    }
                }
            }
        }
        return planes
    }
}

nonisolated extension MatteMachine {
    /// This PC, or the one BEZZLE_MATTE_MACHINE describes for trying another's ways here
    /// (`init(describing:)`). Asks Direct3D for the graphics card, so first asked away from the
    /// main thread (`SubjectModel` does).
    static var this: MatteMachine { asked.machine }
    /// This PC's graphics card by name, for the trace; empty without one Direct3D 12 runs on.
    static var card: String { asked.card }

    private static let asked: (machine: MatteMachine, card: String) = {
        if let said = ProcessInfo.processInfo.environment["BEZZLE_MATTE_MACHINE"], let machine = MatteMachine(describing: said) {
            return (machine, "as BEZZLE_MATTE_MACHINE says")
        }
        var memory: Int64 = 0, dedicated: Int64 = 0, cores: Int32 = 0, software: Int32 = 0
        var name = [CChar](repeating: 0, count: 256)
        let has = bz_matte_machine(&memory, &cores, &dedicated, &software, &name, Int32(name.count))
        // Windows' own adapter on the processor is no card, whatever memory it says it has.
        let card = has != 0 && software == 0 ? UInt64(max(dedicated, 0)) : 0
        return (MatteMachine(memory: memory > 0 ? UInt64(memory) : ProcessInfo.processInfo.physicalMemory,
                             cores: cores > 0 ? Int(cores) : ProcessInfo.processInfo.activeProcessorCount, dedicated: card),
                has != 0 ? String(cString: name) : "")
    }()
}

/// The learned subject matte as this PC makes it. The model comes with Bezzle: its graphs and
/// their weights in Bezzle.resources beside Bezzle.exe (the installer puts them there, build.ps1
/// for a copy built here).
///
/// The model asks more than many PCs have. So each matte is made by the best way this PC can
/// afford for the picture (`ways`, from `MatteWays.routes`), and no way is trusted blindly:
/// - a way that fails is followed by the next lighter one, down to the light size on the
///   processor, which every PC can afford. After that there is none: Windows has no way without
///   the model, as the Mac has with Apple's Vision;
/// - a way that took Bezzle down with it is remembered, and passed over from then on;
/// - a way that took far too long here is passed over for a lighter one;
/// - a way on the processor is taken only while Windows has the memory left that it holds
///   (`MatteWays.fit`): the fine size is passed over for the light one, and the light size, with
///   less than it holds left, is made the lean way, which holds less and takes longer for the
///   same matte;
/// - the model is let go a while after its last picture, and at once when memory runs short. On
///   the processor it is let go after each matte: ONNX Runtime kept hold there of the gigabytes
///   a matte took, and of more with each (CBezzleHost/matte.cpp), so only a model loaded ahead
///   and not yet asked waits its while.
///
/// The last pictures' mattes are kept, so picking other subjects in a picture just cut out asks
/// the model nothing.
///
/// For trying things: BEZZLE_MATTE_ROUTE takes one way alone (gpu2048, cpu2048, gpu1024,
/// cpu1024), BEZZLE_MATTE_MACHINE another PC's ways ("16:8", "32:12:8": gigabytes, fast cores,
/// the card's gigabytes), BEZZLE_MATTE_DEVICE=cpu the processor's ways only (gpu: the card's ways
/// through DirectML on any adapter, a software one too, the light size at least),
/// BEZZLE_MATTE_LEAN=1 the processor's lean way whatever memory is left (0: never),
/// BEZZLE_MATTE_LEFT the ways of a PC with so many gigabytes of memory left ("1.5"), and
/// BEZZLE_MATTE_MODEL other graphs: a folder of them, or one graph that every way then runs.
/// After each matte `log` hears how long it took and what Bezzle has held (`held`).
public nonisolated final class SubjectModel: @unchecked Sendable {
    public static let shared = SubjectModel()

    typealias Machine = MatteMachine

    /// Bezzle's version, which the app says as it starts: a way that took Bezzle down is passed
    /// over by that version, and tried again by the next.
    nonisolated(unsafe) public static var appVersion = ""
    /// Hears where the model runs, or why it could not (the app's trace, a tool's output).
    nonisolated(unsafe) public static var log: ((String) -> Void)?

    // MARK: What is kept

    /// One picture at a time: the model is large, and running it twice at once only slows both.
    private let busy = NSLock()
    private let state = NSLock()
    private let opening = NSLock()
    private var looked = false
    private var graphs = Graphs()
    private var book: MatteLedger?
    private var loaded: SubjectMatte?
    /// Whether the loaded model has made a matte yet: its first takes the graphics card longer.
    private var ran = false
    private var uses = 0
    private var kept = KeptMattes<CutoutMaker.Plane>()
    private var watching = false
    private var lastTrouble: String?

    private init() {}

    /// Why the model could last not be loaded or run, if it could not.
    public var trouble: String? { state.withLock { lastTrouble } }

    // MARK: The model's files

    /// The model's graphs, by the side of their square; or `only` one, which every way runs.
    struct Graphs: Sendable {
        var bySide: [Int: URL] = [:]
        var only: URL?
        /// The side of the `only` graph, once it has been opened and said.
        var onlySide: Int?

        /// Whether a matte can be made at all: with the light size's graph, which the lightest
        /// way runs.
        var isThere: Bool { only != nil || bySide[MatteRoute.light.side] != nil }
        /// Whether the fine size's graph is there too.
        var hasFine: Bool { only != nil || bySide[MatteRoute.fine.side] != nil }
        func url(for route: MatteRoute) -> URL? { only ?? bySide[route.side] }
    }

    /// The graphs that come with Bezzle, those there with the weights they read; or what
    /// BEZZLE_MATTE_MODEL names, a folder with such graphs or one graph alone.
    static func find() -> Graphs {
        var folder = Bundle.main.resourceURL
        if let path = ProcessInfo.processInfo.environment["BEZZLE_MATTE_MODEL"], !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return Graphs() }
            guard isFolder.boolValue else { return Graphs(only: url) }
            folder = url
        }
        guard let folder, FileManager.default.fileExists(atPath: folder.appendingPathComponent("BiRefNet.weights").path) else { return Graphs() }
        var found = Graphs()
        for route in [MatteRoute.light, .fine] {
            let url = folder.appendingPathComponent(route.graph)
            if FileManager.default.fileExists(atPath: url.path) { found.bySide[route.side] = url }
        }
        return found
    }

    /// Whether Bezzle can take backgrounds away here: the model's light size at least, and ONNX
    /// Runtime beside Bezzle (looked for, not loaded: that waits until a background is taken away).
    public static var isAvailable: Bool {
        let runtime = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("onnxruntime.dll")
        return find().isThere && FileManager.default.fileExists(atPath: runtime.path)
    }

    private var files: Graphs {
        state.withLock {
            if !looked {
                looked = true
                graphs = Self.find()
            }
            return graphs
        }
    }

    /// What is remembered of the ways, read the first time it is asked for: this PC is asked
    /// what it is like then, away from the main thread.
    private var ledger: MatteLedger {
        if let book = state.withLock({ book }) { return book }
        return opening.withLock {
            if let book = state.withLock({ book }) { return book }
            let machine = MatteMachine.this
            let made = MatteLedger(machine: machine, version: Self.appVersion, forced: ProcessInfo.processInfo.environment["BEZZLE_MATTE_ROUTE"])
            let gigabytes = { (bytes: UInt64) in String(format: "%.1f GB", Double(bytes) / MatteMachine.gigabyte) }
            let card = machine.dedicated > 0 ? "\(MatteMachine.card) with \(gigabytes(machine.dedicated)) of its own" : "no graphics card with memory of its own"
            Self.log?("subject matte: this PC has \(gigabytes(machine.memory)), \(machine.cores) fast cores, \(card)")
            if let route = made.wentDownWith {
                Self.log?("Bezzle went down while making a subject matte (\(route)): it makes them a lighter way from now on.")
            }
            state.withLock { book = made }
            return made
        }
    }

    /// What BEZZLE_MATTE_DEVICE asks for.
    private enum Asked { case processor, anyAdapter }
    private static let asked: Asked? = switch ProcessInfo.processInfo.environment["BEZZLE_MATTE_DEVICE"]?.lowercased() {
    case "cpu", "processor": .processor
    case "gpu", "directml": .anyAdapter
    default: nil
    }

    // MARK: Asking

    /// The ways to make a matte of a picture `longest` pixels long here and now, the first to
    /// take first: this PC's, without those that took Bezzle down or took too long, without the
    /// card while memory is short, and without the fine size where its graph is missing. None
    /// where the model is not there.
    func ways(longest: Int) -> [MatteRoute] {
        let files = self.files
        guard files.isThere else { return [] }
        let memory = Self.memory()
        var ways = ledger.ways(longest: longest, short: memory.map { MatteWays.memoryIsShort(load: $0.load, available: $0.available) } ?? false,
                               fine: files.hasFine, available: memory?.available)
        guard ProcessInfo.processInfo.environment["BEZZLE_MATTE_ROUTE"] == nil else { return ways }
        switch Self.asked {
        case .processor: ways.removeAll(where: \.onCard)
        case .anyAdapter: if !ways.contains(where: \.onCard) { ways.insert(.lightOnCard, at: 0) }
        case nil: break
        }
        return ways
    }

    /// How finely a picture `longest` pixels long is cut out here and now: plainly where the
    /// model is not there (which on Windows is not at all).
    func grade(longest: Int) -> MatteGrade { grade(by: ways(longest: longest)) }

    /// How finely the first of `ways` cuts out.
    private func grade(by ways: [MatteRoute]) -> MatteGrade {
        guard let first = ways.first else { return .plain }
        // One graph for every way cuts as finely as it is large, whatever the way.
        if let side = files.onlySide { return side >= MatteRoute.fine.side ? .fine : .light }
        return first.grade
    }

    /// How long loading the model and making the matte are expected to take for the picture
    /// called `key`, `longest` pixels long, by the way it takes first: nothing where its matte is
    /// kept. For saying from its start how far along a cut is.
    func expecting(longest: Int, key: String) -> [CutoutPace.Step: Double] {
        let routes = ways(longest: longest)
        guard let route = routes.first else { return [:] }
        let wanted = grade(by: routes), lean = isLean(route)
        let (has, ready) = state.withLock { (kept.matte(of: key, atLeast: wanted) != nil, loaded?.route == route && loaded?.lean == lean ? ran : nil) }
        guard !has else { return [.load: 0, .matte: 0] }
        return ledger.expecting(route, loading: ready == nil, cold: ready != true, lean: lean)
    }

    /// What BEZZLE_MATTE_LEAN asks for: every matte on the processor the lean way (1) or none (0).
    private static let askedLean: Bool? = switch ProcessInfo.processInfo.environment["BEZZLE_MATTE_LEAN"] {
    case "1": true
    case "0": false
    default: nil
    }

    /// Whether `route` is made the lean way just now: on the processor, where the quick way
    /// asks more memory than Windows has left to hand out (`MatteWays.fit`).
    private func isLean(_ route: MatteRoute) -> Bool {
        guard !route.onCard else { return false }
        if let asked = Self.askedLean { return asked }
        return MatteWays.fit(route, available: Self.memory()?.available) != .quick
    }

    /// The matting for one cut of the picture called `key`, which `told` hears the steps of; nil
    /// where no model is to be had. `anyKept` takes a matte kept of the picture however fine: for
    /// finding the picture's parts, which the light size shows as well.
    func cut(of key: String, anyKept: Bool = false, told: @escaping @Sendable (CutoutMaker.Progress) -> Void = { _ in }) -> Cut? {
        files.isThere ? Cut(model: self, key: key, anyKept: anyKept, told: told) : nil
    }

    /// One picture's matte, made the best way that works, which `grade` then says.
    final class Cut: CutoutMaker.Matting, @unchecked Sendable {
        private let model: SubjectModel
        private let key: String
        private let anyKept: Bool
        private let told: @Sendable (CutoutMaker.Progress) -> Void
        private let lock = NSLock()
        private var made: MatteGrade?
        private var ran: String?

        fileprivate init(model: SubjectModel, key: String, anyKept: Bool, told: @escaping @Sendable (CutoutMaker.Progress) -> Void) {
            self.model = model
            self.key = key
            self.anyKept = anyKept
            self.told = told
        }

        /// How finely the matte was made, once it has been.
        var grade: MatteGrade? { lock.withLock { made } }
        /// Where it was made, in words, once it has been: the way and the device, or that it was kept.
        var device: String? { lock.withLock { ran } }

        func matte(of picture: CutoutMaker.Pixels) throws -> CutoutMaker.Plane {
            let (matte, grade, device) = try model.matte(of: picture, key: key, anyKept: anyKept, told: told)
            lock.withLock {
                made = grade
                ran = device
            }
            return matte
        }
    }

    /// Makes ready what a picture `longest` pixels long is cut out by, ahead of being asked for
    /// its matte: the model loaded, to be kept a while. Behind everything else with a picture
    /// only selected; sooner when `pointing` at what takes the background away, as a click may
    /// follow. Loading is most of a first wait on a graphics card.
    func warm(longest: Int, pointing: Bool = true) {
        DispatchQueue.global(qos: pointing ? .userInitiated : .utility).async { [self] in
            // A picture only selected may never be cut out: not worth memory that is short.
            if !pointing, Self.memoryIsShort() { return }
            let files = self.files
            guard let route = ways(longest: longest).first, let url = files.url(for: route), busy.try() else { return }
            defer { busy.unlock() }
            let lean = isLean(route)
            guard state.withLock({ loaded?.route != route || loaded?.lean != lean }) else { return }
            _ = try? load(url, route, lean: lean)
            letGo(after: route)
        }
    }

    // MARK: Making

    private func matte(of picture: CutoutMaker.Pixels, key: String, anyKept: Bool,
                       told: (CutoutMaker.Progress) -> Void) throws -> (CutoutMaker.Plane, MatteGrade, String) {
        busy.lock()
        defer { busy.unlock() }
        let files = self.files
        let longest = max(picture.w, picture.h), routes = ways(longest: longest)
        // The matte kept of this picture, unless a finer one is to be had by now.
        let wanted = anyKept ? MatteGrade.plain : grade(by: routes)
        if let found = state.withLock({ kept.matte(of: key, atLeast: wanted) }) { return (found.matte, found.grade, "kept") }
        var trouble: Swift.Error = CutoutMaker.Failure.unreadable
        for route in routes {
            guard let url = files.url(for: route) else { continue }
            // By what is left now: a way that failed before this one may have taken memory with it.
            let free = Self.memory()?.available, lean = isLean(route)
            let ready = state.withLock { loaded?.route == route && loaded?.lean == lean ? loaded : nil }
            let cold = ready == nil || !state.withLock { ran }
            told(CutoutMaker.Progress(step: ready == nil ? .load : .matte, expecting: ledger.expecting(route, loading: ready == nil, cold: cold, lean: lean)))
            do {
                let model = try ready ?? load(url, route, lean: lean)
                if ready == nil { told(CutoutMaker.Progress(step: .matte)) }
                let began = WindowsCore.now
                ledger.mark(route, running: true)
                defer { ledger.mark(route, running: false) }
                let matte = try model.matte(of: picture)
                let took = WindowsCore.now - began
                ledger.remember(matte: took, by: route, cold: cold, lean: lean)
                let grade = model.grade, device = "\(route) on \(model.device)"
                Self.log?("subject matte: \(device), made in \(String(format: "%.2f", took)) s\(Self.held(before: free, onCard: route.onCard))")
                state.withLock {
                    ran = true
                    kept.keep(matte, of: key, grade: grade)
                    // On the processor the model is let go with its matte made (see above).
                    if !route.onCard {
                        loaded = nil
                        ran = false
                    }
                }
                if route.onCard { letGo(after: route) }
                return (matte, grade, device)
            } catch {
                Self.log?("Bezzle could not make a subject matte (\(route)): \(error)")
                state.withLock {
                    loaded = nil
                    ran = false
                    lastTrouble = "\(error)"
                }
                trouble = error
            }
        }
        throw trouble
    }

    /// The model made ready for `route`, on the processor the `lean` way when asked; any other
    /// let go first: two at once would hold both their memory.
    private func load(_ url: URL, _ route: MatteRoute, lean: Bool) throws -> SubjectMatte {
        state.withLock {
            loaded = nil
            ran = false
        }
        let began = WindowsCore.now
        ledger.mark(route, running: true)
        defer { ledger.mark(route, running: false) }
        let model: SubjectMatte
        do {
            model = try SubjectMatte(contentsOf: url, route: route, anyAdapter: route.onCard && Self.asked == .anyAdapter, lean: lean)
        } catch {
            state.withLock { lastTrouble = "\(error)" }
            throw error
        }
        ledger.remember(loading: WindowsCore.now - began, for: route)
        Self.log?("subject matte: \(url.lastPathComponent) at \(model.side) pixels on \(model.device) (\(route)), loaded in \(String(format: "%.2f", WindowsCore.now - began)) s")
        state.withLock {
            loaded = model
            if graphs.only != nil { graphs.onlySide = model.side }
        }
        watch()
        return model
    }

    /// Lets the model go once it has not been asked for a while: soon on the graphics card,
    /// where it holds gigabytes for as long as it is kept.
    private func letGo(after route: MatteRoute) {
        let mine = state.withLock { () -> Int in
            uses += 1
            return uses
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (route.onCard ? 45 : 300)) { [weak self] in
            guard let self, self.state.withLock({ self.uses }) == mine else { return }
            self.letGo(forgetting: false)
        }
    }

    /// Lets the model go, unless it is at work; `forgetting` the mattes kept too.
    private func letGo(forgetting: Bool) {
        guard busy.try() else { return }
        defer { busy.unlock() }
        state.withLock {
            loaded = nil
            ran = false
            if forgetting { kept.forget() }
        }
    }

    /// While the model is kept, memory is asked after every few seconds, as Windows tells no
    /// one when it runs short: the model is then let go at once, and the mattes kept with it.
    private func watch() {
        let begins = state.withLock { () -> Bool in
            guard !watching else { return false }
            watching = true
            return true
        }
        if begins { look() }
    }

    private func look() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            if Self.memoryIsShort() { self.letGo(forgetting: true) }
            let goesOn = self.state.withLock { () -> Bool in
                if self.loaded == nil { self.watching = false }
                return self.watching
            }
            if goesOn { self.look() }
        }
    }

    /// What BEZZLE_MATTE_LEFT says Windows has left to hand out, in gigabytes ("1.5"): for trying
    /// here what Bezzle does on a PC whose memory is nearly all in use.
    private static let askedLeft: UInt64? = ProcessInfo.processInfo.environment["BEZZLE_MATTE_LEFT"]
        .flatMap { Double($0) }.map { UInt64(max($0, 0) * MatteMachine.gigabyte) }

    /// What Windows says of memory just now: the share in use, in percent, and the bytes it can
    /// still hand out. Nothing where it does not say.
    static func memory() -> (load: Int, available: UInt64)? {
        var load: Int32 = 0, available: Int64 = 0
        guard bz_matte_memory(&load, &available) != 0 else { return nil }
        return (Int(load), askedLeft ?? UInt64(max(available, 0)))
    }

    /// Whether Windows says memory is short just now.
    static func memoryIsShort() -> Bool {
        memory().map { MatteWays.memoryIsShort(load: $0.load, available: $0.available) } ?? false
    }

    /// For the trace, after a matte: the most memory Bezzle has held since it started and the
    /// most it had asked Windows for, what the graphics card holds for it now, and what was
    /// `free` before the matte. Measuring a way on a PC is reading this line
    /// (Scripts/subject-matte/README.md, Measuring a graphics card).
    private static func held(before free: UInt64?, onCard: Bool) -> String {
        var peak: Int64 = 0, asked: Int64 = 0, card: Int64 = 0, shared: Int64 = 0
        // The card is asked only after a matte made on it: asking takes Direct3D a moment.
        guard (onCard ? bz_matte_held(&peak, &asked, &card, &shared) : bz_matte_held(&peak, &asked, nil, nil)) != 0 else { return "" }
        let gigabytes = { (bytes: Int64) in String(format: "%.2f GB", Double(bytes) / MatteMachine.gigabyte) }
        var said = "; Bezzle has held \(gigabytes(peak)) at most and asked Windows for \(gigabytes(asked))"
        if onCard { said += "; the graphics card holds \(gigabytes(card)) of its own for it now and \(gigabytes(shared)) of the PC's" }
        if let free { said += "; \(gigabytes(Int64(free))) were free before" }
        return said
    }

    /// Bezzle is quitting: a matte cut short by that is no matte that took Bezzle down.
    public func quitting() {
        state.withLock { book }?.quitting()
    }
}
