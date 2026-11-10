import Foundation
import CBezzleHost

// From Bezzle/Store/CutoutOperations.swift: a picture cut out into a new picture beside it, named as
// the Mac names it, so a cutout made on either is found by the other in a shared design.

extension WindowsCore {
    /// What the cutout of a picture is called (`CutoutNames`, the Mac's names letter for letter):
    /// for how finely it was cut out, so a plainer cutout is never taken for a finer one.
    nonisolated static func cutoutName(of asset: String, picks: [CGPoint]?, grade: SubjectMatte.Grade) -> String {
        CutoutNames.name(of: asset, picks: picks, grade: grade)
    }

    /// The outline of a cutout, from how solid it is as it was kept: the same however it came to be
    /// there, made here, made before, or made by someone sharing the design.
    nonisolated static func cutoutOutline(of cutout: URL) throws -> String {
        guard let data = try? Data(contentsOf: cutout), let image = CutoutMaker.Pixels(file: data, longest: 1024) else {
            throw CutoutMaker.Failure.unreadable
        }
        return CutoutMaker.outline(of: image)
    }

    /// The cutout of the picture `asset` in `folder`: one made before, as finely as this PC would
    /// make it or finer (on a computer with more to it, say, sharing the design), or made now by
    /// `model` and kept as a PNG beside the picture. `told` hears each step. Without the model,
    /// only a cutout made before can be shown again: Windows has no plainer way to find a subject.
    nonisolated static func cutout(of asset: String, in folder: URL, picks: [CGPoint]?, model: SubjectModel = .shared,
                                   told: @escaping @Sendable (CutoutMaker.Progress) -> Void = { _ in }) throws -> Cutout {
        let source = folder.appendingPathComponent(asset)
        var w: Int32 = 0, h: Int32 = 0
        guard let data = try? Data(contentsOf: source),
              data.withUnsafeBytes({ bz_image_size($0.baseAddress, Int32(clamping: $0.count), &w, &h) }) != 0, w > 0, h > 0
        else { throw CutoutMaker.Failure.unreadable }
        let longest = min(Int(max(w, h)), CutoutMaker.Tuning().workSide), megapixels = Double(w) * Double(h) / 1e6
        let wanted = model.grade(longest: longest)
        for made in CutoutNames.names(of: asset, picks: picks, atLeast: wanted) {
            let url = folder.appendingPathComponent(made.name)
            if FileManager.default.fileExists(atPath: url.path) {
                return Cutout(asset: made.name, picks: picks, outline: try cutoutOutline(of: url))
            }
        }

        let steps = Steps()
        let hear: @Sendable (CutoutMaker.Progress) -> Void = { progress in
            steps.note(progress)
            told(progress)
        }
        guard let matting = model.cut(of: source.path, told: hear) else { throw CutoutTrouble.noMatte }
        // How long reading and finishing took a megapixel here before says how long they take
        // now, and the way the picture takes first how long its model and its matte.
        let times = CutoutTimes()
        hear(CutoutMaker.Progress(step: .look, expecting: times.expecting(megapixels: megapixels)
                .merging(model.expecting(longest: longest, key: source.path)) { _, known in known }))
        // At its own size, turned upright as it is drawn.
        guard let picture = CutoutMaker.Pixels(file: data) else { throw CutoutMaker.Failure.unreadable }
        let cut = try CutoutMaker.cut(picture, picks: picks, matting: matting, told: hear)
        let target = folder.appendingPathComponent(cutoutName(of: asset, picks: picks, grade: matting.grade ?? wanted))
        try keep(cut, at: target)
        let outline = try cutoutOutline(of: target)
        let ended = WindowsCore.now
        // Reading lasts until the model is asked, or until finishing where the matte was kept.
        if let began = steps.began(.look) {
            let read = [CutoutPace.Step.load, .matte, .finish].compactMap { steps.began($0) }.min()
            times.remember(reading: read.map { $0 - began }, finishing: steps.began(.finish).map { ended - $0 }, megapixels: megapixels)
        }
        return Cutout(asset: target.lastPathComponent, picks: picks, outline: outline)
    }

    /// When each step of a cut was told.
    private nonisolated final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [CutoutPace.Step: Double] = [:]

        func note(_ progress: CutoutMaker.Progress) { lock.withLock { times[progress.step] = times[progress.step] ?? progress.at } }
        func began(_ step: CutoutPace.Step) -> Double? { lock.withLock { times[step] } }
    }

    /// `cut` kept as a PNG at `target`: written beside it first, so a cutout cut short is never
    /// taken for one made.
    nonisolated static func keep(_ cut: CutoutMaker.Pixels, at target: URL) throws {
        let writing = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: writing) }
        guard let png = encodePNG(cut) else { throw CutoutMaker.Failure.unreadable }
        do { try png.write(to: writing) } catch { throw CutoutMaker.Failure.unreadable }
        // Another cutting out of the same picture may have put it there meanwhile: it is the same.
        if !FileManager.default.fileExists(atPath: target.path) {
            do { try FileManager.default.moveItem(at: writing, to: target) } catch { throw CutoutMaker.Failure.unreadable }
        }
    }

    /// Pixels as a PNG file's bytes, carrying the profile of their colours, as Image I/O writes the
    /// Mac's cutouts: a Display P3 photo's cutout stays Display P3.
    nonisolated static func encodePNG(_ p: CutoutMaker.Pixels) -> Data? {
        var capacity = Int64(p.w * p.h * 4 + 65536 + (p.colors?.count ?? 0))
        let icc = p.colors ?? Data()
        for _ in 0..<2 {
            var out = Data(count: Int(capacity))
            let written = p.bytes.withUnsafeBytes { from in
                icc.withUnsafeBytes { profile in
                    out.withUnsafeMutableBytes {
                        bz_png_encode_own(Int32(p.w), Int32(p.h), from.baseAddress, 0, profile.baseAddress, Int32(profile.count), $0.baseAddress, capacity)
                    }
                }
            }
            if written > 0 { return out.prefix(Int(written)) }
            guard written < -1 else { return nil }
            capacity = -written
        }
        return nil
    }
}

// MARK: - Taking backgrounds away in the open design

extension WindowsCore {
    /// A picture being cut out, as the canvas and the inspector show it while it is (the Mac's
    /// CutoutWork).
    public struct CutoutWork {
        /// Which asking it is of: one given up is taken away, and what its work comes to is left be.
        let run: UUID
        /// How far along it is by the clock, which the canvas and the inspector read each time
        /// they draw.
        var pace: CutoutPace
        /// Roughly where the subject is, once it has been found.
        public var found: CutoutFound?
        /// The cutout, once it is made: the canvas makes the cut, and the design then shows it.
        var made: Cutout?
        /// When it began, on the clock animations run by (`now`).
        public let began = WindowsCore.now
    }

    /// Where the subject was found, for the canvas to draw its line in to (the Mac's CutoutTool is
    /// given a grey picture): a value a pixel across the whole picture, rows top first, 255 on the
    /// subject, at most 400 across.
    public struct CutoutFound: Sendable {
        public let width: Int, height: Int
        public let inside: [UInt8]
    }

    /// The layers whose pictures are being cut out in the open design (the Mac's store.cuttingOut).
    nonisolated(unsafe) public internal(set) static var cuttingOut: [UUID: CutoutWork] = [:]
    /// Why the background could not be taken away, said in the inspector for a moment (the Mac's
    /// cutoutTrouble), in Bezzle's English words for the app to say in its language.
    nonisolated(unsafe) public internal(set) static var cutoutTrouble: String?
    /// Told, on the main thread, when a design's cutting out moved on (`edited` when the design
    /// changed): the window of that design draws it again.
    nonisolated(unsafe) public static var cutoutsChanged: (@MainActor (_ slot: Slot?, _ edited: Bool) -> Void)?

    /// Why a background could not be taken away, in the Mac's words (and Windows' own).
    nonisolated enum CutoutTrouble: Swift.Error, CustomStringConvertible {
        case noPictures, readOnly, noMatte, failed(CutoutMaker.Failure)

        /// As the inspector says it, in English (the app translates).
        var description: String {
            switch self {
            case .noPictures: "Only a layer filled with a picture has a background to take away."
            case .readOnly: "This design can only be looked at."
            case .noMatte: "Bezzle cannot find subjects on this PC: what finds them did not load."
            case .failed(.noSubject): "Nothing in the picture stands out from its background."
            case .failed(.nothingPicked): "Nothing stands out where the picture was picked."
            case .failed(.unreadable): "The picture could not be read."
            }
        }
    }

    /// Whether Bezzle takes backgrounds away here: its subject matte and ONNX Runtime are beside it.
    public static var removesBackground: Bool {
        if let known = knowsMatte { return known }
        let known = SubjectModel.isAvailable
        knowsMatte = known
        return known
    }
    nonisolated(unsafe) private static var knowsMatte: Bool?

    /// The layers among `ids` filled with a picture, that are not locked.
    private static func pictures(_ ids: [UUID]) -> [Node] {
        guard let doc = design else { return [] }
        return ids.compactMap { doc.node($0) }.filter { !$0.isArtboard && !$0.locked && $0.fill.on && $0.fill.image != nil }
    }

    /// Whether every one of `ids` is filled with a picture a subject can be cut out of: not text,
    /// whose letters it would leave little of (the Mac's Fill card asks the same).
    public static func cutsOut(_ ids: [UUID]) -> Bool {
        guard let doc = design, !ids.isEmpty else { return false }
        return ids.allSatisfy { id in doc.node(id).map { $0.fill.on && $0.fill.image != nil && $0.kind != .text } ?? false }
    }

    public static func canRemoveBackground(_ ids: [UUID]) -> Bool {
        removesBackground && !isReadOnly && cuttingOut.isEmpty && pictures(ids).contains { $0.fill.image?.cutout == nil }
    }

    public static func canRestoreBackground(_ ids: [UUID]) -> Bool {
        !isReadOnly && pictures(ids).contains { $0.fill.image?.cutout != nil }
    }

    /// Whether the pictures filling `ids` show their subject alone: cut out, or being cut out;
    /// nil when some do and some do not, or none is a picture.
    public static func showsSubjectAlone(_ ids: [UUID]) -> Bool? {
        let those = pictures(ids)
        guard !those.isEmpty else { return nil }
        if ids.contains(where: { cuttingOut[$0] != nil }) { return true }
        let cut = those.map { $0.fill.image?.cutout != nil }
        if cut.allSatisfy({ $0 }) { return true }
        return cut.allSatisfy { !$0 } ? false : nil
    }

    /// How far the cutting out of the pictures filling `ids` has come by now, the least of them,
    /// 0…1; nil when none is being cut out. Said from the clock (`CutoutPace`), so it moves each
    /// time it is asked, also while the model says nothing of itself for many seconds.
    public static func cutoutProgress(_ ids: [UUID]) -> Double? {
        let now = now
        return ids.compactMap { cuttingOut[$0]?.pace.done(at: now) }.min()
    }

    /// Gives up taking the background away from the pictures filling `ids`: they stay whole, and
    /// the canvas lets its line go. A cutout nearly made is still finished and kept beside its
    /// picture, to be found made the next time it is asked for.
    public static func giveUpRemovingBackground(_ ids: [UUID]) {
        let given = ids.filter { cuttingOut[$0] != nil }
        guard !given.isEmpty else { return }
        for id in given { cuttingOut[id] = nil }
        cutoutsChanged?(active, false)
    }

    /// Makes ready what finds subjects, for the pictures filling `ids`: the model loaded, which is
    /// most of a first wait, and kept a while. Behind everything else with a picture only
    /// selected, and once for a selection however often it is said; sooner when `pointing` at what
    /// takes the background away, as a click may follow.
    public static func readyToRemoveBackground(_ ids: [UUID], pointing: Bool = true) {
        guard canRemoveBackground(ids), let size = pictures(ids).first(where: { $0.fill.image?.cutout == nil })?.fill.image?.size else { return }
        if !pointing {
            guard madeReadyFor != ids else { return }
            madeReadyFor = ids
        }
        SubjectModel.shared.warm(longest: Int(min(max(size.width, size.height), CGFloat(CutoutMaker.Tuning().workSide))), pointing: pointing)
    }
    /// The selection the model was last made ready for.
    nonisolated(unsafe) private static var madeReadyFor: [UUID] = []

    /// Takes the background away from the pictures filling `ids`, saying in the inspector why
    /// when it could not.
    public static func removeBackground(_ ids: [UUID]) {
        let ids = pictures(ids).filter { $0.fill.image?.cutout == nil }.map(\.id)
        guard !ids.isEmpty else { return }
        cutoutTrouble = nil
        let slot = active
        Task {
            do {
                try await cutOut(ids, picks: nil)
            } catch {
                trouble(error, in: slot)
            }
        }
    }

    /// Says in the inspector, for a moment, why a background could not be taken away.
    public static func trouble(_ error: Swift.Error, in slot: Slot?) {
        let said = (error as? CutoutTrouble)?.description ?? "The picture could not be cut out."
        within(slot) { cutoutTrouble = said }
        cutoutsChanged?(slot, false)
        Task {
            try? await Task.sleep(for: .seconds(6))
            var gone = false
            within(slot) {
                if cutoutTrouble == said {
                    cutoutTrouble = nil
                    gone = true
                }
            }
            if gone { cutoutsChanged?(slot, false) }
        }
    }

    /// Shows the pictures filling `ids` whole again.
    public static func restoreBackground(_ ids: [UUID]) {
        let cut = pictures(ids).filter { $0.fill.image?.cutout != nil }.map(\.id)
        guard !cut.isEmpty else { return }
        edit { d in for id in cut { d.update(id) { $0.fill.image?.cutout = nil } } }
    }

    /// `body` with `slot`'s design as the one worked on, if it is still open; with no slots (a
    /// tool without tabs), as it is.
    private static func within(_ slot: Slot?, _ body: () -> Void) {
        guard let slot else { body(); return }
        guard slot.isOpen else { return }
        using(slot, body)
    }

    /// Cuts out the pictures filling `ids`: the subjects at `picks`, 0…1 across and down each
    /// picture, or all that stand out. A picture filling several layers is cut out once. Returns
    /// the layers that show a cutout now: those still showing the picture they had once it is
    /// made, and not given up meanwhile. The design is the one in front as it is asked; it may go
    /// behind meanwhile.
    @discardableResult
    public static func cutOut(_ ids: [UUID], picks: [CGPoint]? = nil) async throws -> [UUID] {
        guard !isReadOnly else { throw CutoutTrouble.readOnly }
        let slot = active
        var layers: [String: [UUID]] = [:]
        for id in ids {
            guard let n = design?.node(id), n.fill.on, let image = n.fill.image else { continue }
            layers[image.asset, default: []].append(id)
        }
        guard let folder = assets.folder, !layers.isEmpty else { throw CutoutTrouble.noPictures }
        let run = UUID()
        // Until the work says what it expects (`cutout(of:)`, as it begins to look).
        let pace = CutoutPace(expected: [.look: 0.5, .matte: 5, .finish: 1], at: now)
        for id in ids { cuttingOut[id] = CutoutWork(run: run, pace: pace) }
        cutoutsChanged?(slot, false)
        defer {
            within(slot) { for id in ids where cuttingOut[id]?.run == run { cuttingOut[id] = nil } }
            cutoutsChanged?(slot, false)
        }

        var made: [String: Cutout] = [:], problem: CutoutTrouble?
        for asset in layers.keys.sorted() {
            // Each step told to the layers it fills, as it is taken: the canvas and the inspector
            // then read the pace themselves, frame by frame.
            let showing = layers[asset] ?? []
            let told: @Sendable (CutoutMaker.Progress) -> Void = { progress in
                let found = progress.found.map { Self.found($0) }
                Task { @MainActor in
                    within(slot) {
                        for id in showing where cuttingOut[id]?.run == run {
                            cuttingOut[id]?.pace.begin(progress.step, expecting: progress.expecting, at: progress.at)
                            if let found { cuttingOut[id]?.found = found }
                        }
                    }
                    cutoutsChanged?(slot, false)
                }
            }
            do {
                // Cut out before, and given back since, it is shown again as it was.
                let cutout = try await Task.detached(priority: .userInitiated) {
                    try Self.cutout(of: asset, in: folder, picks: picks, told: told)
                }.value
                // Skia is given it by its name, as the design's other pictures.
                if let data = try? Data(contentsOf: folder.appendingPathComponent(cutout.asset)) { giveSkia(cutout.asset, data) }
                made[asset] = cutout
            } catch {
                // No way of this PC's made a matte: what finds subjects did not load, or did not run.
                problem = problem ?? (error as? CutoutTrouble ?? (error is SubjectMatte.Trouble ? .noMatte : .failed(error as? CutoutMaker.Failure ?? .unreadable)))
            }
        }
        if made.isEmpty, let problem { throw problem }

        // Made: where a window shows it, its canvas makes the cut first (`CutoutHand`), and the
        // design shows the cutout as the cut comes round.
        let ended = now
        var shows = false
        within(slot) {
            for (asset, ids) in layers {
                for id in ids where cuttingOut[id]?.run == run {
                    cuttingOut[id]?.pace.end(at: ended)
                    cuttingOut[id]?.made = made[asset]
                    shows = true
                }
            }
        }
        cutoutsChanged?(slot, false)
        if cutoutsChanged != nil, shows { try? await Task.sleep(for: .seconds(CutoutMotion.untilCut)) }

        // After the click that asked for it is over, and after any drag going on meanwhile: a step
        // of the undo history of its own.
        while slot?.isOpen ?? true, inGesture(slot) { try? await Task.sleep(for: .milliseconds(200)) }
        var shown: [UUID] = [], edited = false
        within(slot) {
            guard design != nil else { return }
            // Not the layers given up meanwhile.
            let mine = Set(ids.filter { cuttingOut[$0]?.run == run })
            guard layers.contains(where: { made[$0.key] != nil && $0.value.contains(where: mine.contains) }) else { return }
            edited = true
            edit { d in
                for (asset, ids) in layers {
                    guard let cutout = made[asset] else { continue }
                    for id in ids where mine.contains(id) {
                        d.update(id) { n in
                            guard n.fill.image?.asset == asset else { return }
                            n.fill.image?.cutout = cutout
                            shown.append(id)
                        }
                    }
                }
            }
        }
        if edited { cutoutsChanged?(slot, true) }
        return shown
    }

    /// Whether a drag is going on in `slot`'s design, whose steps a change made now would be lost in.
    private static func inGesture(_ slot: Slot?) -> Bool {
        var dragging = false
        within(slot) { dragging = Editing.gestureStart != nil }
        return dragging
    }

    /// Where the subject was found, as the canvas is told it: from the subject at the size it was
    /// worked on, made small.
    nonisolated static func found(_ subject: CutoutMaker.Plane) -> CutoutFound {
        let shrink = min(1, 400 / Double(max(subject.w, subject.h, 1)))
        let w = max(1, Int(Double(subject.w) * shrink)), h = max(1, Int(Double(subject.h) * shrink))
        let small = shrink < 1 ? CutoutMaker.resample(subject, w, h) : subject
        return CutoutFound(width: w, height: h, inside: (0..<(w * h)).map { small.p[$0] >= 0.5 ? 255 : 0 })
    }
}

// MARK: - Trying it without the app

extension WindowsCore {
    /// What `bezzle-render <fonts> cutout <out>` does with the photos BEZZLE_PHOTOS names (separated
    /// by ;): each cut out as Bezzle cuts it out, into `out` as <name>-cutout.png with its outline
    /// (<name>-outline.txt), the matte as the model made it (<name>-matte.png, and with
    /// BEZZLE_MATTE_RAW its floats, as many as the model's square, <name>-matte.f32, and what the
    /// model was given, <name>-input.f32), and the parts a click keeps or drops (<name>-parts.txt);
    /// BEZZLE_PICKS ("x,y;x,y") keeps only some. Says how long each step took, which way the
    /// matte was made and where (BEZZLE_MATTE_ROUTE and BEZZLE_MATTE_MACHINE choose, see
    /// `SubjectModel`); BEZZLE_MATTE_TWICE makes the matte twice, the second time as it is made
    /// with the model loaded (on the graphics card: the processor's is loaded anew for each).
    public static func tryCutouts(_ photos: [URL], into out: URL) async -> [String] {
        var said: [String] = []
        guard SubjectModel.find().isThere else { return ["no subject matte: none at BEZZLE_MATTE_MODEL or beside Bezzle"] }
        let environment = ProcessInfo.processInfo.environment
        let picks: [CGPoint]? = environment["BEZZLE_PICKS"].map { text in
            text.split(separator: ";").compactMap { pair in
                let xy = pair.split(separator: ",").compactMap { Double($0) }
                return xy.count == 2 ? CGPoint(x: xy[0], y: xy[1]) : nil
            }
        }
        let raw = environment["BEZZLE_MATTE_RAW"] != nil, twice = environment["BEZZLE_MATTE_TWICE"] != nil
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for photo in photos {
            let name = photo.deletingPathExtension().lastPathComponent
            let lines = await Task.detached(priority: .userInitiated) { () -> [String] in
                var lines: [String] = []
                func time<T>(_ what: String, _ body: () throws -> T) rethrows -> T {
                    let t0 = Date()
                    let made = try body()
                    lines.append("\(name): \(what) \(String(format: "%.3f", Date().timeIntervalSince(t0))) s")
                    return made
                }
                guard let data = try? Data(contentsOf: photo), let picture = time("read", { CutoutMaker.Pixels(file: data) }) else {
                    return ["\(name): could not be read"]
                }
                // The matte alone, of the picture as it is worked on, timed: the first with loading
                // the model (twice, asked: the first matte after loading is slower on a graphics card).
                let shrink = min(1, 2048 / Double(max(picture.w, picture.h)))
                let ww = max(1, Int((Double(picture.w) * shrink).rounded())), wh = max(1, Int((Double(picture.h) * shrink).rounded()))
                guard let work = (shrink < 1 ? picture.scaled(ww, wh) : picture)?.overWhite() else { return ["\(name): could not be scaled"] }
                lines.append("\(name): \(picture.w)x\(picture.h), ways \(SubjectModel.shared.ways(longest: max(ww, wh)).map(\.description).joined(separator: ", "))")
                guard let matting = SubjectModel.shared.cut(of: name) else { return lines + ["\(name): no subject matte"] }
                do {
                    let learned = try time("model and matte", { try matting.matte(of: work) })
                    lines.append("\(name): matte made by \(matting.device ?? "nothing"), \(learned.w) pixels square")
                    if twice, let again = SubjectModel.shared.cut(of: "\(name) again") {
                        _ = try time("matte again", { try again.matte(of: work) })
                        lines.append("\(name): matte made again by \(again.device ?? "nothing")")
                    }
                    if raw {
                        let floats = Data(bytes: learned.p, count: learned.count * 4)
                        try? floats.write(to: out.appendingPathComponent("\(name)-matte.f32"))
                        // And what the model was given: red, green and blue planes, as large as its square.
                        if let input = try? SubjectMatte.square(work, side: learned.w) {
                            try? input.withUnsafeBytes { Data($0) }.write(to: out.appendingPathComponent("\(name)-input.f32"))
                        }
                    }
                    let small = CutoutMaker.resample(learned, ww, wh)
                    var grey = [UInt8](repeating: 255, count: ww * wh * 4)
                    for i in 0..<(ww * wh) {
                        let v = UInt8(min(max(small.p[i], 0), 1) * 255 + 0.5)
                        grey[i * 4] = v; grey[i * 4 + 1] = v; grey[i * 4 + 2] = v
                    }
                    if let png = encodePNG(CutoutMaker.Pixels(w: ww, h: wh, bytes: grey)) { try? png.write(to: out.appendingPathComponent("\(name)-matte.png")) }
                    let subjects = time("parts", { CutoutMaker.subjects(of: small, ww, wh) })
                    let parts = subjects.parts.map { p in
                        String(format: "%.4f,%.4f %.0f%%", Double(p.point.x), Double(p.point.y),
                               Double(p.outline.boundingBoxOfPath.width * p.outline.boundingBoxOfPath.height) * 100)
                    }
                    try? parts.joined(separator: "\n").write(to: out.appendingPathComponent("\(name)-parts.txt"), atomically: true, encoding: .utf8)
                    lines.append("\(name): \(subjects.parts.count) part(s): \(parts.joined(separator: " | "))")
                    // The cutout, with the matte just made (it is kept).
                    let target = out.appendingPathComponent("\(name)-cutout.png")
                    try? FileManager.default.removeItem(at: target)
                    let outline = try time("cutout", { () -> String in
                        try keep(try CutoutMaker.cut(picture, picks: picks, matting: matting), at: target)
                        return try cutoutOutline(of: target)
                    })
                    try? outline.write(to: out.appendingPathComponent("\(name)-outline.txt"), atomically: true, encoding: .utf8)
                    lines.append("\(name): outline \(outline.count) characters")
                } catch {
                    lines.append("\(name): \(error)")
                }
                return lines
            }.value
            said += lines
        }
        return said
    }
}
