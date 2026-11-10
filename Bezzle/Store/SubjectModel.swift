import AppKit
import CoreML
import Foundation

/// The learned subject matte as this Mac makes it. The model comes with the app, BiRefNet.mlpackage
/// beside `SubjectMatte`, compiled when the app is built (Scripts/subject-matte makes it);
/// BEZZLE_MATTE_MODEL takes another, and tests run without one unless given it.
///
/// The model asks more than many Macs have: at its fine size on the GPU it holds 9 GB. So each
/// matte is made by the best way this Mac can afford for the picture (`routes`), and no way is
/// trusted blindly:
/// - a way that fails is followed by the next lighter one, and the last of them by `CutoutMaker`'s
///   own way without the model, less fine round hair;
/// - a way that took Bezzle down with it is remembered, and passed over from then on;
/// - a way that took far too long here is passed over for a lighter one;
/// - a way never taken here before is not taken first: Core ML fits the model to the Mac the
///   first time, which takes many times as long as any matte after it (`isReady`). The picture
///   is cut out by a way that is ready, or by the quickest to make ready, and the best way is
///   made ready behind it, for the next picture;
/// - the model is let go a while after its last picture, and at once when memory runs short, as
///   on the GPU it holds its gigabytes for as long as it is kept.
///
/// The last pictures' mattes are kept, so picking other subjects in a picture just cut out asks
/// the model nothing.
nonisolated final class SubjectModel: @unchecked Sendable {
    static let shared = SubjectModel()

    // MARK: Which way

    /// What of a Mac decides how it makes a matte.
    struct Machine: Sendable, Equatable {
        /// Its memory, in bytes.
        var memory: UInt64
        /// Its cores but for the efficiency cores.
        var fastCores: Int
        var appleSilicon: Bool

        /// This Mac, or the one BEZZLE_MATTE_MACHINE describes for trying a smaller one's ways
        /// here: gigabytes, fast cores and arm or intel, as "8:4:arm".
        static let this: Machine = {
            if let said = ProcessInfo.processInfo.environment["BEZZLE_MATTE_MACHINE"]?.split(separator: ":"), said.count == 3,
               let gigabytes = Double(said[0]), let cores = Int(said[1]) {
                return Machine(memory: UInt64(gigabytes * 1_073_741_824), fastCores: cores, appleSilicon: said[2] != "intel")
            }
            #if arch(arm64)
            let arm = true
            #else
            let arm = false
            #endif
            return Machine(memory: ProcessInfo.processInfo.physicalMemory, fastCores: fastCores(), appleSilicon: arm)
        }()

        private static func fastCores() -> Int {
            func number(_ name: String) -> Int? {
                var value: Int32 = 0, size = MemoryLayout<Int32>.size
                return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
            }
            func word(_ name: String) -> String? {
                var size = 0
                guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
                var bytes = [CChar](repeating: 0, count: size)
                guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
                return String(cString: bytes)
            }
            let all = number("hw.physicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
            guard let levels = number("hw.nperflevels"), levels > 0 else { return all }
            let fast = (0..<levels).reduce(0) { sum, level in
                word("hw.perflevel\(level).name") == "Efficiency" ? sum : sum + (number("hw.perflevel\(level).physicalcpu") ?? 0)
            }
            return fast > 0 ? fast : all
        }
    }

    /// A picture this many pixels along its longer side, as it is worked on, has something for
    /// the fine size to find. A smaller one would only be blown up for it, and the light size
    /// finds as much in it, in a quarter of the memory and the time.
    static let fineFrom = 1536

    /// The ways `machine` makes a matte of a picture `longest` pixels along its longer side, the
    /// one to take first, and after each the one to take should it fail. None where the model
    /// is too much for the machine at any size.
    ///
    /// The GPU is far the fastest (a matte in a fraction of a second) and holds far the most, for
    /// as long as the model is kept: 9 GB at the fine size, 3 GB at the light one. So the fine
    /// size there is for Macs of 24 GB and more, the light size for Macs of 16 GB. The processor
    /// takes a fifth of that, and only while it runs, but seconds a matte: the light size there
    /// is what every Mac can do, and the fine size what a Mac with cores enough falls back on.
    static func routes(longest: Int, on machine: Machine) -> [SubjectMatte.Route] {
        let gigabytes = Double(machine.memory) / 1_073_741_824
        let large = longest >= fineFrom, quick = machine.fastCores >= 8
        // An Intel Mac's GPU has not the memory, and its processor needs its cores for the light size.
        guard machine.appleSilicon else { return gigabytes >= 15.5 && quick ? [.light] : [] }
        if gigabytes >= 23.5 && large { return quick ? [.fineOnGPU, .fine, .lightOnGPU, .light] : [.fineOnGPU, .lightOnGPU, .light] }
        if gigabytes >= 15.5 { return [.lightOnGPU, .light] }
        return [.light]
    }

    /// A way that took longer than this many seconds is passed over the next time.
    static let patience = 25.0

    // MARK: What is kept

    private let machine: Machine
    private let defaults: UserDefaults
    private let version: String
    /// Looks for the model, the first time it is asked for.
    private let find: @Sendable () -> URL?
    /// Whether memory is short just now.
    private let short: @Sendable () -> Bool
    /// One picture at a time: the model is large, and running it twice at once only slows both.
    private let busy = NSLock()
    private let state = NSLock()
    private var looked = false
    private var url: URL?
    private var loaded: SubjectMatte?
    /// Whether the loaded model has made a matte yet: its first takes the GPU longer.
    private var ran = false
    private var uses = 0
    /// One way at a time is made ready behind the others, and which one it is.
    private let readying = NSLock()
    private var settling: SubjectMatte.Route?
    /// The ways running just now, as `Key.running` says on disk.
    private var running: Set<SubjectMatte.Route> = []
    private var kept: [(key: String, grade: SubjectMatte.Grade, matte: CutoutMaker.Plane)] = []
    private var pressure: DispatchSourceMemoryPressure?
    private var quitting: NSObjectProtocol?

    init(machine: Machine = .this, defaults: UserDefaults = .standard,
         version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
         find: @escaping @Sendable () -> URL? = SubjectModel.bundled, short: @escaping @Sendable () -> Bool = SubjectModel.memoryIsShort) {
        self.machine = machine
        self.defaults = defaults
        self.version = version
        self.find = find
        self.short = short
        // A way still marked as running was running when Bezzle went down: not taken again by
        // this version of Bezzle.
        // Of two running at once (a picture cut out, and a way made ready behind it), the one
        // that asks the most of the Mac.
        let names = defaults.stringArray(forKey: Key.running) ?? []
        if let name = SubjectMatte.Route.all.filter({ names.contains("\($0)") }).max(by: { $0.holds < $1.holds })?.description {
            var avoided = defaults.dictionary(forKey: Key.avoided) as? [String: String] ?? [:]
            avoided[name] = version
            defaults.set(avoided, forKey: Key.avoided)
            NSLog("Bezzle went down while making a subject matte (%@): it makes them a lighter way from now on.", name)
        }
        defaults.removeObject(forKey: Key.running)
    }

    private enum Key {
        static let running = "subjectMatte.running", avoided = "subjectMatte.avoided", ready = "subjectMatte.ready"
        static func seconds(_ route: SubjectMatte.Route, cold: Bool) -> String { "subjectMatte.seconds.\(route).\(cold ? "cold" : "warm")" }
        static func loading(_ route: SubjectMatte.Route) -> String { "subjectMatte.loading.\(route)" }
    }

    /// The model that comes with the app, or the one BEZZLE_MATTE_MODEL names (a model package
    /// is compiled first); none in a test run that names none.
    static let bundled: @Sendable () -> URL? = {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["BEZZLE_MATTE_MODEL"] {
            let url = URL(fileURLWithPath: path)
            guard url.pathExtension != "mlmodelc" else { return url }
            let made = Made<URL>(), done = DispatchSemaphore(value: 0)
            Task.detached {
                made.value = try? await MLModel.compileModel(at: url)
                done.signal()
            }
            done.wait()
            return made.value
        }
        guard environment["XCTestConfigurationFilePath"] == nil else { return nil }
        return Bundle.main.url(forResource: "BiRefNet", withExtension: "mlmodelc")
    }

    private final class Made<Value>: @unchecked Sendable { var value: Value? }

    private var model: URL? {
        state.withLock {
            if !looked {
                looked = true
                url = find()
                if url != nil { watch() }
            }
            return url
        }
    }

    /// Once there is a model: let go when memory runs short, and a run cut short by quitting is
    /// no run that took Bezzle down.
    private func watch() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.letGo(forgetting: true) }
        source.resume()
        pressure = source
        quitting = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [defaults] _ in
            defaults.removeObject(forKey: Key.running)
        }
    }

    // MARK: Asking

    /// The ways to make a matte of a picture `longest` pixels long here and now, the first to
    /// take first: this Mac's, without those that took Bezzle down or took too long, and without
    /// the GPU while memory is short. BEZZLE_MATTE_ROUTE takes one alone, for trying it.
    func ways(longest: Int) -> [SubjectMatte.Route] {
        if let forced = ProcessInfo.processInfo.environment["BEZZLE_MATTE_ROUTE"] {
            return SubjectMatte.Route.all.filter { $0.description == forced }
        }
        let avoided = defaults.dictionary(forKey: Key.avoided) as? [String: String] ?? [:]
        let short = short()
        return Self.routes(longest: longest, on: machine).filter { route in
            if avoided["\(route)"] == version { return false }
            if route.onGPU && short { return false }
            let took = max(defaults.double(forKey: Key.seconds(route, cold: false)), defaults.double(forKey: Key.seconds(route, cold: true)))
            return took <= Self.patience
        }
    }

    /// How finely a picture `longest` pixels long is cut out here and now: plainly where the
    /// model is not there, or too much for this Mac.
    func grade(longest: Int) -> SubjectMatte.Grade {
        guard model != nil else { return .plain }
        return order(longest: longest).first?.grade ?? .plain
    }

    /// Whether `route` has made a matte here with this version of Bezzle. The first time a way is
    /// taken, Core ML fits the model to this Mac's processor or GPU and keeps what it made: that
    /// takes many times as long as any matte after it (`SubjectMatte.Route.first`).
    func isReady(_ route: SubjectMatte.Route) -> Bool {
        (defaults.dictionary(forKey: Key.ready) as? [String: String])?["\(route)"] == version
    }

    private func setReady(_ route: SubjectMatte.Route) {
        guard !isReady(route) else { return }
        var ready = (defaults.dictionary(forKey: Key.ready) as? [String: String] ?? [:]).filter { $0.value == version }
        ready["\(route)"] = version
        defaults.set(ready, forKey: Key.ready)
    }

    /// The ways in the order to try them for a picture now: those that are ready, as `ways` has
    /// them, then the others, the quickest to make ready first.
    func order(longest: Int) -> [SubjectMatte.Route] {
        let all = ways(longest: longest)
        return all.filter(isReady) + all.filter { !isReady($0) }.sorted { $0.first.load + $0.first.matte < $1.first.load + $1.first.matte }
    }

    /// The matting for one cut of the picture called `key`, which `told` hears the steps of; nil
    /// where no model is to be had.
    func cut(of key: String, told: @escaping @Sendable (CutoutMaker.Progress) -> Void = { _ in }) -> Cut? {
        model == nil ? nil : Cut(model: self, key: key, told: told)
    }

    /// One picture's matte, made the best way that works, which `grade` then says.
    final class Cut: CutoutMaker.Matting, @unchecked Sendable {
        private let model: SubjectModel
        private let key: String
        private let told: @Sendable (CutoutMaker.Progress) -> Void
        private let lock = NSLock()
        private var made: SubjectMatte.Grade?

        fileprivate init(model: SubjectModel, key: String, told: @escaping @Sendable (CutoutMaker.Progress) -> Void) {
            self.model = model
            self.key = key
            self.told = told
        }

        /// How finely the matte was made, once it has been.
        var grade: SubjectMatte.Grade? { lock.withLock { made } }

        func matte(of picture: CGImage) throws -> CutoutMaker.Plane {
            let (matte, grade) = try model.matte(of: picture, key: key, told: told)
            lock.withLock { made = grade }
            return matte
        }
    }

    /// Makes ready what a picture `longest` pixels long is cut out by, ahead of being asked for
    /// its matte. `pointing` at what takes the background away, the model is loaded too, to be
    /// kept a while; without, only a way never taken here is made ready, behind everything else:
    /// that once takes long (`isReady`), and is called for a picture merely selected.
    func warm(longest: Int, pointing: Bool = true) {
        DispatchQueue.global(qos: .utility).async { [self] in
            guard let url = model, let route = order(longest: longest).first else { return }
            guard isReady(route) else { return makeReady(route) }
            guard pointing, busy.try() else { return }
            defer { busy.unlock() }
            guard state.withLock({ loaded?.route }) != route else { return }
            _ = try? load(url, route)
            letGo(after: route)
        }
    }

    /// Makes `route` ready behind everything else: the model fitted to this Mac by making one
    /// matte of nothing, which Core ML keeps. Not while the Mac saves energy, nor on the GPU
    /// while memory is short: it is asked again with the next picture.
    private func makeReady(_ route: SubjectMatte.Route) {
        DispatchQueue.global(qos: .utility).async { [self] in
            guard let url = model, !isReady(route), readying.try() else { return }
            defer { readying.unlock() }
            guard !ProcessInfo.processInfo.isLowPowerModeEnabled, !(route.onGPU && short()) else { return }
            state.withLock { settling = route }
            defer { state.withLock { settling = nil } }
            mark(route, running: true)
            defer { mark(route, running: false) }
            do {
                guard let blank = Self.blank else { return }
                _ = try SubjectMatte(contentsOf: url, route: route).matte(of: blank)
                setReady(route)
            } catch {
                NSLog("Bezzle could not make a subject matte ready (%@): %@", "\(route)", String(describing: error))
            }
        }
    }

    /// A picture of nothing, to make a way ready with.
    private static let blank: CGImage? = {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        ctx?.setFillColor(gray: 0.5, alpha: 1)
        ctx?.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return ctx?.makeImage()
    }()

    // MARK: Making

    private func matte(of picture: CGImage, key: String, told: (CutoutMaker.Progress) -> Void) throws -> (CutoutMaker.Plane, SubjectMatte.Grade) {
        busy.lock()
        defer { busy.unlock() }
        guard let url = model else { throw CutoutMaker.Failure.unreadable }
        var trouble: Error = CutoutMaker.Failure.unreadable
        let longest = max(picture.width, picture.height), routes = order(longest: longest)
        // The matte kept of this picture, unless a finer one is to be had by now.
        if let found = state.withLock({ kept.first { $0.key == key } }), found.grade >= routes.first?.grade ?? .plain {
            return (found.matte, found.grade)
        }
        for route in routes {
            // Being made ready behind, for a picture selected: waited for, not done twice over.
            if state.withLock({ settling }) == route {
                told(CutoutMaker.Progress(step: .load, expecting: expecting(route, loading: true, cold: true)))
                readying.lock()
                readying.unlock()
            }
            let ready = state.withLock { loaded?.route == route ? loaded : nil }
            let cold = ready == nil || !state.withLock { ran }, first = !isReady(route)
            told(CutoutMaker.Progress(step: ready == nil ? .load : .matte, expecting: expecting(route, loading: ready == nil, cold: cold)))
            do {
                let model = try ready ?? load(url, route)
                if ready == nil { told(CutoutMaker.Progress(step: .matte)) }
                let began = CFAbsoluteTimeGetCurrent()
                mark(route, running: true)
                defer { mark(route, running: false) }
                let matte = try model.matte(of: picture)
                // The GPU's first matte ever says nothing of how long the others take.
                if !(first && route.onGPU) { remember(CFAbsoluteTimeGetCurrent() - began, for: Key.seconds(route, cold: cold)) }
                setReady(route)
                state.withLock {
                    ran = true
                    kept.removeAll { $0.key == key }
                    kept.append((key, route.grade, matte))
                    if kept.count > 3 { kept.removeFirst() }
                }
                letGo(after: route)
                // The best way for such a picture, where this was not it: ready for the next.
                if let best = ways(longest: longest).first, best != route, !isReady(best) { makeReady(best) }
                return (matte, route.grade)
            } catch {
                NSLog("Bezzle could not make a subject matte (%@): %@", "\(route)", String(describing: error))
                state.withLock { loaded = nil }
                trouble = error
            }
        }
        throw trouble
    }

    /// The model made ready for `route`, any other let go first: two at once would hold both
    /// their memory.
    private func load(_ url: URL, _ route: SubjectMatte.Route) throws -> SubjectMatte {
        state.withLock {
            loaded = nil
            ran = false
        }
        let began = CFAbsoluteTimeGetCurrent(), first = !isReady(route)
        mark(route, running: true)
        defer { mark(route, running: false) }
        let model = try SubjectMatte(contentsOf: url, route: route)
        if !first { remember(CFAbsoluteTimeGetCurrent() - began, for: Key.loading(route)) }
        state.withLock { loaded = model }
        return model
    }

    /// How long loading and the matte are expected to take by `route`: as long as they took here
    /// before, or by what is known of this Mac; and the first time ever, as long as that takes.
    private func expecting(_ route: SubjectMatte.Route, loading: Bool, cold: Bool) -> [CutoutPace.Step: Double] {
        guard isReady(route) else {
            let slower = route.onGPU ? 1 : max(1, 18 / Double(max(machine.fastCores, 1)))
            return [.load: route.first.load * slower, .matte: route.first.matte * slower]
        }
        let load = defaults.double(forKey: Key.loading(route))
        var matte = defaults.double(forKey: Key.seconds(route, cold: cold))
        if matte <= 0 { matte = route.seconds(fastCores: machine.fastCores) * (cold && route.onGPU ? 4 : 1) }
        return [.load: loading ? (load > 0 ? load : 0.3) : 0, .matte: matte]
    }

    /// How long something took, kept leaning to the last time over those before.
    private func remember(_ seconds: Double, for key: String) {
        let before = defaults.double(forKey: key)
        defaults.set(before > 0 ? before * 0.3 + seconds * 0.7 : seconds, forKey: key)
    }

    /// Says on disk which ways are running, so that Bezzle, started again after going down with
    /// one, knows.
    private func mark(_ route: SubjectMatte.Route, running on: Bool) {
        let names = state.withLock { () -> [String] in
            if on { running.insert(route) } else { running.remove(route) }
            return running.map(\.description).sorted()
        }
        if names.isEmpty { defaults.removeObject(forKey: Key.running) } else { defaults.set(names, forKey: Key.running) }
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }

    /// Lets the model go once it has not been asked for a while: soon on the GPU, where it holds
    /// gigabytes for as long as it is kept.
    private func letGo(after route: SubjectMatte.Route) {
        let mine = state.withLock { () -> Int in
            uses += 1
            return uses
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (route.onGPU ? 45 : 300)) { [weak self] in
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
            if forgetting { kept.removeAll() }
        }
    }

    /// Whether macOS says memory is short just now.
    static let memoryIsShort: @Sendable () -> Bool = {
        var level: Int32 = 0, size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 && level >= 2
    }
}
