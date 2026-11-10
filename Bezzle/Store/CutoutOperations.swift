import Foundation
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

/// A picture being cut out, as the canvas and the inspector show it while it is.
struct CutoutWork {
    /// Which asking it is of: one given up is taken away, and what its work comes to is left be.
    let run: UUID
    /// How far along it is by the clock, which the canvas reads each time it draws.
    var pace: CutoutPace
    /// How far along it was a moment ago, 0…1: for the inspector.
    var done: Double = 0
    /// Roughly where the subject is, once it has been found: grey, white on it.
    var found: CGImage?
    /// The cutout, once it is made: the canvas makes the cut, and the design then shows it.
    var made: Cutout?
    /// When it began, on the clock animations run by.
    let began = CACurrentMediaTime()
}

/// Taking the background away from pictures, and giving it back. The picture is cut out away
/// from the main thread, into a new picture beside it, and the layers it fills then show that in
/// one step of the undo history. See `CutoutMaker` and `Cutout`.
extension DocumentStore {
    enum CutoutTrouble: Error, CustomStringConvertible {
        case noPictures, readOnly, failed(CutoutMaker.Failure)

        /// For an assistant, as the inspector says it.
        var description: String { String(localized: message) }

        /// For the inspector, in the language the app is shown in.
        var message: LocalizedStringResource {
            switch self {
            case .noPictures: "Only a layer filled with a picture has a background to take away."
            case .readOnly: "This design can only be looked at."
            case .failed(.noSubject): "Nothing in the picture stands out from its background."
            case .failed(.nothingPicked): "Nothing stands out where the picture was picked."
            case .failed(.unreadable): "The picture could not be read."
            }
        }
    }

    /// The selected layers filled with a picture, that are not locked.
    private var selectedPictures: [Node] {
        selectedNodes.filter { !$0.isArtboard && !$0.locked && $0.fill.on && $0.fill.image != nil }
    }

    var canRemoveBackground: Bool {
        !isReadOnly && cuttingOut.isEmpty && selectedPictures.contains { $0.fill.image?.cutout == nil }
    }

    var canRestoreBackground: Bool {
        !isReadOnly && selectedPictures.contains { $0.fill.image?.cutout != nil }
    }

    /// Takes the background away from the selected layers' pictures, telling the inspector if it
    /// could not.
    func removeBackground() {
        let ids = selectedPictures.filter { $0.fill.image?.cutout == nil }.map(\.id)
        guard !ids.isEmpty else { return }
        cutoutTrouble = nil
        Task {
            do {
                try await cutOut(ids)
            } catch {
                trouble(error)
            }
        }
    }

    /// Says in the inspector, for a moment, why a background could not be taken away.
    func trouble(_ error: Error) {
        let shown = (error as? CutoutTrouble)?.message ?? "The picture could not be cut out."
        cutoutTrouble = shown
        Task {
            try? await Task.sleep(for: .seconds(6))
            if cutoutTrouble?.key == shown.key { cutoutTrouble = nil }
        }
    }

    /// Gives up taking the background away from the selected layers' pictures: they stay whole.
    /// A cutout nearly made is still finished and kept beside its picture, to be found made the
    /// next time it is asked for.
    func giveUpRemovingBackground() {
        for id in selection where cuttingOut[id] != nil { cuttingOut[id] = nil }
    }

    /// Makes ready what finds subjects, for the selected pictures. `pointing` at what takes a
    /// background away, the model is loaded, which is most of a first wait; with a picture only
    /// selected, what this Mac has never done before is done behind everything else, which the
    /// first time ever takes many times as long (`SubjectModel.isReady`).
    func readyToRemoveBackground(pointing: Bool = true) {
        guard canRemoveBackground, let size = selectedPictures.first(where: { $0.fill.image?.cutout == nil })?.fill.image?.size else { return }
        SubjectModel.shared.warm(longest: Int(min(max(size.width, size.height), CGFloat(CutoutMaker.Tuning().workSide))), pointing: pointing)
    }

    /// Shows the selected layers' pictures whole again.
    func restoreBackground() {
        update(selectedPictures.filter { $0.fill.image?.cutout != nil }.map(\.id), "Restore Background") { $0.fill.image?.cutout = nil }
    }

    /// Cuts out the pictures filling `ids`: the subjects at `picks`, 0…1 across and down each
    /// picture, or all that stand out. A picture filling several layers is cut out once. Returns
    /// the layers that show a cutout now: those still showing the picture they had once it is
    /// made, and not given up meanwhile.
    @discardableResult
    func cutOut(_ ids: [UUID], picks: [CGPoint]? = nil) async throws -> [UUID] {
        guard !isReadOnly else { throw CutoutTrouble.readOnly }
        var layers: [String: [UUID]] = [:]
        for id in ids {
            guard let n = node(id), n.fill.on, let image = n.fill.image else { continue }
            layers[image.asset, default: []].append(id)
        }
        guard let folder = assets.folder, !layers.isEmpty else { throw CutoutTrouble.noPictures }
        let run = UUID()
        for id in ids { cuttingOut[id] = CutoutWork(run: run, pace: CutoutPace(expected: [.look: 0.5, .matte: 1.5, .finish: 0.5], at: CACurrentMediaTime())) }
        defer { for id in ids where cuttingOut[id]?.run == run { cuttingOut[id] = nil } }
        // The inspector hears how far it is a few times a second; the canvas asks the pace itself.
        let ticking = Task { [weak self] in
            while !Task.isCancelled, let self {
                let now = CACurrentMediaTime()
                for id in ids where self.cuttingOut[id]?.run == run {
                    if let done = self.cuttingOut[id]?.pace.done(at: now) { self.cuttingOut[id]?.done = done }
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
        defer { ticking.cancel() }

        var made: [String: Cutout] = [:], trouble: CutoutMaker.Failure?
        for asset in layers.keys.sorted() {
            // Each step told to the layers it fills, as it is taken.
            let showing = layers[asset] ?? []
            let told: @Sendable (CutoutMaker.Progress) -> Void = { [weak self] progress in
                Task { @MainActor [weak self] in
                    for id in showing where self?.cuttingOut[id]?.run == run {
                        self?.cuttingOut[id]?.pace.begin(progress.step, expecting: progress.expecting, at: progress.at)
                        if let found = progress.found { self?.cuttingOut[id]?.found = found }
                    }
                }
            }
            do {
                made[asset] = try await Task.detached(priority: .userInitiated) {
                    try Self.cutout(of: asset, in: folder, picks: picks, told: told)
                }.value
            } catch {
                trouble = trouble ?? (error as? CutoutMaker.Failure ?? .unreadable)
            }
        }
        if made.isEmpty, let trouble { throw CutoutTrouble.failed(trouble) }

        // Made: where the canvas shows it, it makes the cut first (`CutoutTool`), and the design
        // shows the cutout as the cut comes round.
        let ended = CACurrentMediaTime()
        for (asset, ids) in layers {
            for id in ids where cuttingOut[id]?.run == run {
                cuttingOut[id]?.pace.end(at: ended)
                cuttingOut[id]?.done = 1
                cuttingOut[id]?.made = made[asset]
            }
        }
        if canvas != nil, !made.isEmpty { try? await Task.sleep(for: .seconds(CutoutMotion.untilCut)) }

        var next = doc, shown: [UUID] = []
        for (asset, ids) in layers {
            guard let cutout = made[asset] else { continue }
            for id in ids where cuttingOut[id]?.run == run {
                next.update(id) { n in
                    guard n.fill.image?.asset == asset else { return }
                    n.fill.image?.cutout = cutout
                    shown.append(id)
                }
            }
        }
        guard next != doc else { return [] }
        // Made after the click that asked for it is over: a step of the undo history of its own,
        // which would otherwise wait open for the next click's.
        if let undo = undoManager {
            let byEvent = undo.groupsByEvent
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            edit("Remove Background") { $0 = next }
            undo.endUndoGrouping()
            undo.groupsByEvent = byEvent
        } else {
            edit("Remove Background") { $0 = next }
        }
        return shown
    }

    /// What the cutout of a picture is called: the same each time it is cut out with the same
    /// picks, so taking the background away again finds it made, however often it was given back.
    /// It is named for how finely it was cut out: with the learned matte, for the model's version
    /// and, at the light size, for that, so a plainer cutout is never taken for a finer one.
    nonisolated static func cutoutName(of asset: String, picks: [CGPoint]?, grade: SubjectMatte.Grade = .plain) -> String {
        let made = switch grade {
        case .plain: "-cutout"
        case .light: "-cutout-m\(SubjectMatte.version)-1024"
        case .fine: "-cutout-m\(SubjectMatte.version)"
        }
        let stem = (asset as NSString).deletingPathExtension + made
        guard let picks, !picks.isEmpty else { return "\(stem).png" }
        // FNV-1a over the picks to a ten-thousandth, the same on every Mac and every run.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in picks.map({ String(format: "%.4f,%.4f", $0.x, $0.y) }).joined(separator: ";").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return "\(stem)-\(String(hash, radix: 16)).png"
    }

    /// The outline of a cutout, from how solid it is as it was kept: the same however it came to be
    /// there, made here, made before, or made by someone sharing the design.
    nonisolated static func outline(of cutout: URL) throws -> String {
        guard let file = CGImageSourceCreateWithURL(cutout as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(file, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024,
              ] as CFDictionary)
        else { throw CutoutMaker.Failure.unreadable }
        return CutoutMaker.outline(of: image)
    }

    /// The cutout of the picture `asset` in `folder`: one made before, as finely as this Mac
    /// would make it or finer (on a Mac with more to it, say, sharing the design), or made now,
    /// by `model` where there is one, and kept as a PNG beside the picture. `told` hears each step.
    nonisolated static func cutout(of asset: String, in folder: URL, picks: [CGPoint]?, model: SubjectModel? = .shared,
                                   told: @escaping @Sendable (CutoutMaker.Progress) -> Void = { _ in }) throws -> Cutout {
        let source = folder.appendingPathComponent(asset)
        guard let file = CGImageSourceCreateWithURL(source as CFURL, nil),
              let info = CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [CFString: Any],
              let w = info[kCGImagePropertyPixelWidth] as? Int, let h = info[kCGImagePropertyPixelHeight] as? Int
        else { throw CutoutMaker.Failure.unreadable }
        let longest = min(max(w, h), CutoutMaker.Tuning().workSide), megapixels = Double(w * h) / 1e6
        let wanted = model?.grade(longest: longest) ?? .plain
        for grade in SubjectMatte.Grade.allCases.reversed() where grade >= wanted {
            let made = folder.appendingPathComponent(cutoutName(of: asset, picks: picks, grade: grade))
            if FileManager.default.fileExists(atPath: made.path) {
                return Cutout(asset: made.lastPathComponent, picks: picks, outline: try outline(of: made))
            }
        }

        // How long reading and finishing took a megapixel here before says how long they take now.
        let defaults = UserDefaults.standard
        let reading = defaults.double(forKey: "cutout.reading"), finishing = defaults.double(forKey: "cutout.finishing")
        let began = CACurrentMediaTime()
        let steps = Steps()
        let hear: @Sendable (CutoutMaker.Progress) -> Void = { progress in
            steps.note(progress)
            told(progress)
        }
        hear(CutoutMaker.Progress(step: .look, expecting: [
            .look: 0.3 + megapixels * (reading > 0 ? reading : 0.02), .finish: 0.15 + megapixels * (finishing > 0 ? finishing : 0.1),
        ]))
        // At its own size, turned upright as it is drawn.
        guard let picture = CGImageSourceCreateThumbnailAtIndex(file, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
        ] as CFDictionary) else { throw CutoutMaker.Failure.unreadable }
        let read = CACurrentMediaTime()
        let matting = model?.cut(of: source.path, told: hear)
        let cut = try CutoutMaker.cut(picture, picks: picks, matting: matting, told: hear)
        let target = folder.appendingPathComponent(cutoutName(of: asset, picks: picks, grade: matting?.grade ?? .plain))
        try keep(cut, at: target)
        let outline = try outline(of: target)
        let ended = CACurrentMediaTime()
        func remember(_ seconds: Double, _ key: String) {
            let before = defaults.double(forKey: key), now = seconds / max(megapixels, 0.25)
            defaults.set(before > 0 ? (before + now) / 2 : now, forKey: key)
        }
        remember(read - began, "cutout.reading")
        if let finish = steps.began(.finish) { remember(ended - finish, "cutout.finishing") }
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
    private nonisolated static func keep(_ cut: CGImage, at target: URL) throws {
        let writing = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: writing) }
        guard let out = CGImageDestinationCreateWithURL(writing as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CutoutMaker.Failure.unreadable
        }
        CGImageDestinationAddImage(out, cut, nil)
        guard CGImageDestinationFinalize(out) else { throw CutoutMaker.Failure.unreadable }
        // Another cutting out of the same picture may have put it there meanwhile: it is the same.
        if !FileManager.default.fileExists(atPath: target.path) {
            do { try FileManager.default.moveItem(at: writing, to: target) } catch { throw CutoutMaker.Failure.unreadable }
        }
    }
}
