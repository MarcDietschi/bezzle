import Foundation
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

/// A picture being cut out, as the canvas and the inspector show it while it is.
struct CutoutWork {
    /// How far along, 0…1.
    var done: Double = 0
    /// Roughly where the subject is, once it has been found: grey, white on it.
    var found: CGImage?
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

    /// Shows the selected layers' pictures whole again.
    func restoreBackground() {
        update(selectedPictures.filter { $0.fill.image?.cutout != nil }.map(\.id), "Restore Background") { $0.fill.image?.cutout = nil }
    }

    /// Cuts out the pictures filling `ids`: the subjects at `picks`, 0…1 across and down each
    /// picture, or all that stand out. A picture filling several layers is cut out once. Returns
    /// the layers that show a cutout now: those still showing the picture they had once it is made.
    @discardableResult
    func cutOut(_ ids: [UUID], picks: [CGPoint]? = nil) async throws -> [UUID] {
        guard !isReadOnly else { throw CutoutTrouble.readOnly }
        var layers: [String: [UUID]] = [:]
        for id in ids {
            guard let n = node(id), n.fill.on, let image = n.fill.image else { continue }
            layers[image.asset, default: []].append(id)
        }
        guard let folder = assets.folder, !layers.isEmpty else { throw CutoutTrouble.noPictures }
        for id in ids { cuttingOut[id] = CutoutWork() }
        defer { for id in ids { cuttingOut[id] = nil } }

        // The learned matte, unless every picture was cut out with it before.
        let fine = { (asset: String) in folder.appendingPathComponent(Self.cutoutName(of: asset, picks: picks, learned: true)) }
        let matte = layers.keys.allSatisfy({ FileManager.default.fileExists(atPath: fine($0).path) }) ? nil : await SubjectModel.shared.matte()

        var made: [String: Cutout] = [:], trouble: CutoutMaker.Failure?
        for asset in layers.keys.sorted() {
            let learned = matte != nil || FileManager.default.fileExists(atPath: fine(asset).path)
            let name = Self.cutoutName(of: asset, picks: picks, learned: learned)
            let source = folder.appendingPathComponent(asset), target = folder.appendingPathComponent(name)
            // Each step told to the layers it fills, as it is taken.
            let showing = layers[asset] ?? []
            let told: @Sendable (CutoutMaker.Progress) -> Void = { [weak self] progress in
                Task { @MainActor [weak self] in
                    for id in showing {
                        self?.cuttingOut[id]?.done = progress.done
                        if let found = progress.found { self?.cuttingOut[id]?.found = found }
                    }
                }
            }
            do {
                // Cut out before, and given back since, it is shown again as it was.
                let outline = try await Task.detached(priority: .userInitiated) {
                    FileManager.default.fileExists(atPath: target.path)
                        ? try Self.outline(of: target)
                        : try Self.makeCutout(of: source, picks: picks, to: target, matting: matte, told: told)
                }.value
                made[asset] = Cutout(asset: name, picks: picks, outline: outline)
            } catch {
                trouble = trouble ?? (error as? CutoutMaker.Failure ?? .unreadable)
            }
        }
        if made.isEmpty, let trouble { throw CutoutTrouble.failed(trouble) }

        var next = doc, shown: [UUID] = []
        for (asset, ids) in layers {
            guard let cutout = made[asset] else { continue }
            for id in ids {
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
    /// Cut out with the learned matte, it is named for the model's version, so one cut without it
    /// is never taken for one cut with it.
    nonisolated static func cutoutName(of asset: String, picks: [CGPoint]?, learned: Bool = false) -> String {
        let stem = (asset as NSString).deletingPathExtension + (learned ? "-cutout-m\(SubjectMatte.version)" : "-cutout")
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

    /// The picture at `source` cut out, and kept as a PNG at `target`: written beside it first, so
    /// a cutout cut short is never taken for one made. Returns the outline of what it leaves.
    nonisolated static func makeCutout(of source: URL, picks: [CGPoint]?, to target: URL, matting: (any CutoutMaker.Matting)? = nil,
                                       told: (CutoutMaker.Progress) -> Void = { _ in }) throws -> String {
        // At its own size, turned upright as it is drawn.
        guard let file = CGImageSourceCreateWithURL(source as CFURL, nil),
              let info = CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [CFString: Any],
              let w = info[kCGImagePropertyPixelWidth] as? Int, let h = info[kCGImagePropertyPixelHeight] as? Int,
              let picture = CGImageSourceCreateThumbnailAtIndex(file, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(w, h),
              ] as CFDictionary)
        else { throw CutoutMaker.Failure.unreadable }
        let cut = try CutoutMaker.cut(picture, picks: picks, matting: matting, told: told)
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
        let outline = try outline(of: target)
        told(CutoutMaker.Progress(done: 1))
        return outline
    }
}
