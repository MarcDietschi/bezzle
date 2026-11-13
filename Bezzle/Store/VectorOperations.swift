import AppKit
import QuartzCore

/// A picture being vectorized, as the canvas shows it while it is.
struct VectorWork {
    /// When it began, on the clock animations run by.
    let began = CACurrentMediaTime()
}

/// A picture just vectorized, for the canvas to show it turning into shapes.
struct VectorReveal {
    /// Where the picture lay on the canvas, and how it was turned.
    let frame: CGRect
    let rotation: Double
    let image: CGImage
    /// The larger shapes' outlines, in the picture layer's own coordinates.
    let outlines: CGPath
    let at = CACurrentMediaTime()
}

/// Vectorize: the picture filling a layer made the shapes it shows, as layers of the design.
/// The picture is traced away from the main thread (`VectorMaker`), and the group of layers
/// then takes the picture layer's place, with its id, in one step of the undo history. While the
/// design stays open, the group remembers its picture: the Vector card traces it again with
/// more or less detail, other colours or calmer outlines, and gives the picture back.
extension DocumentStore {
    enum VectorTrouble: Error, CustomStringConvertible {
        case noPictures, readOnly, nothing

        /// For an assistant.
        var description: String { String(localized: message) }

        var message: LocalizedStringResource {
            switch self {
            case .noPictures: "Only a layer filled with a picture can be vectorized."
            case .readOnly: "This design can only be looked at."
            case .nothing: "Nothing was found in the picture to trace."
            }
        }
    }

    static let vectorizing = LocalizedStringResource("undo.vectorize", defaultValue: "Vectorize", comment: "Menu command and undo name: a picture is traced into shapes")
    private static let vectorPreview = "vector"

    /// Whether a layer shows a picture that can become shapes (`BezzleDocument.vectorizable`).
    func vectorizable(_ id: UUID) -> Bool { doc.vectorizable(id) }

    var canVectorize: Bool { !isReadOnly && vectorizing.isEmpty && selection.contains(where: vectorizable) }

    /// Makes the selected layers' pictures shapes.
    func vectorize() {
        let ids = selection.filter(vectorizable)
        guard !ids.isEmpty, vectorizing.isEmpty else { return }
        if editingPicture != nil { editingPicture = nil }
        Task {
            do { try await vectorize(ids) } catch { NSSound.beep() }
        }
    }

    /// Makes the pictures filling `ids` shapes: each layer becomes a group of layers, with its
    /// id. Returns those that did.
    @discardableResult
    func vectorize(_ ids: [UUID], settings: VectorSettings = VectorSettings()) async throws -> [UUID] {
        guard !isReadOnly else { throw VectorTrouble.readOnly }
        let pictures = ids.filter(vectorizable).compactMap { node($0) }
        guard !pictures.isEmpty else { throw VectorTrouble.noPictures }
        for picture in pictures { vectorizing[picture.id] = VectorWork() }
        defer { for picture in pictures { vectorizing[picture.id] = nil } }

        var made: [(picture: Node, pixels: VectorMaker.Source, made: VectorMaker.Made)] = []
        let assets = assets
        for picture in pictures {
            let result = await Task.detached(priority: .userInitiated) { () -> (VectorMaker.Source, VectorMaker.Made)? in
                guard let pixels = VectorMaker.source(of: picture, assets: assets),
                      let made = VectorMaker.make(pixels, settings, replacing: picture) else { return nil }
                return (pixels, made)
            }.value
            if let result { made.append((picture, result.0, result.1)) }
        }
        guard !made.isEmpty else { throw VectorTrouble.nothing }

        // Only those still as they were when their picture was read.
        made = made.filter { node($0.picture.id) == $0.picture }
        var next = doc
        var reveals: [UUID: VectorReveal] = [:]
        for (picture, pixels, result) in made {
            guard let at = next.path(of: picture.id), let frame = doc.absoluteFrame(of: picture.id) else { continue }
            // Not `update`, which keeps where each layer is known: a group holds new layers.
            next[at] = result.group
            reveals[picture.id] = VectorReveal(frame: frame, rotation: picture.rotation, image: pixels.image, outlines: result.outlines)
        }
        guard next != doc else { return [] }
        editApart(Self.vectorizing) { $0 = next }
        var shown: [UUID] = []
        for (picture, pixels, result) in made {
            guard let group = node(picture.id), group.kind == .group, let first = group.children.first else { continue }
            var source = traced[picture.id].flatMap { $0.picture == picture ? $0 : nil } ?? VectorSource(picture: picture, pixels: pixels)
            source.remember(group, settings, shapes: result.shapes, colors: result.colors)
            traced[picture.id] = source
            vectorReveals[picture.id] = reveals[picture.id]
            shown.append(picture.id)
        }
        forgetVectors(keeping: shown)
        canvas?.needsDisplay = true
        return shown
    }

    /// A change made after the click that asked for it is over: a step of the undo history of
    /// its own, which would otherwise wait open for the next click's.
    func editApart(_ action: LocalizedStringResource, _ change: (inout BezzleDocument) -> Void) {
        guard let undo = undoManager, !inGesture else {
            edit(action, change)
            return
        }
        let byEvent = undo.groupsByEvent
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        edit(action, change)
        undo.endUndoGrouping()
        undo.groupsByEvent = byEvent
    }

    /// Pictures are remembered for a few vectors at a time: each holds its pixels.
    private func forgetVectors(keeping kept: [UUID]) {
        for id in Array(traced.keys) where vector(of: id) == nil && !kept.contains(id) && node(id)?.fill.image == nil { traced[id] = nil }
        while traced.count > 6, let other = traced.keys.first(where: { !kept.contains($0) && !selection.contains($0) }) { traced[other] = nil }
    }

    // MARK: A vector and its picture

    /// The picture a group of layers was vectorized from, and how, while it is still the layers
    /// that were made of it: moved, resized and looking as it likes, but holding what it held.
    func vector(of id: UUID) -> (source: VectorSource, version: VectorSource.Version)? {
        guard let source = traced[id], let group = node(id), let version = source.version(of: group) else { return nil }
        return (source, version)
    }

    /// How a vector is traced, or is about to be.
    func vectorSettings(of id: UUID) -> VectorSettings? {
        vector(of: id).map { vectorWanted[id] ?? $0.version.settings }
    }

    /// How many shapes and which colours a vector has, as the canvas shows it just now.
    func vectorCounts(of id: UUID) -> (shapes: Int, colors: [RGBA])? {
        if let previewed = vectorPreviewed[id] { return previewed }
        return vector(of: id).map { ($0.version.shapes, $0.version.colors) }
    }

    /// The picture layer as it would lie now, where its vector lies and as large, and moving in
    /// its film as its vector does now: keys set since it became shapes are not the picture's to lose.
    private func lying(_ source: VectorSource, _ version: VectorSource.Version, as group: Node) -> Node {
        source.lying(version, as: group)
    }

    /// Changes how a vector is traced, and traces its picture again. During a drag the canvas
    /// shows a quick tracing of each amount the drag passes; once it is let go, the picture is
    /// traced in full, and the design changes in one step.
    func setVector(_ id: UUID, _ change: (inout VectorSettings) -> Void) {
        guard !isReadOnly, let (_, version) = vector(of: id) else { return }
        var wanted = vectorWanted[id] ?? version.settings
        change(&wanted)
        wanted = wanted.held
        guard wanted != (vectorWanted[id] ?? version.settings) else { return }
        vectorWanted[id] = wanted
        guard !retracing.contains(id) else { return }
        retracing.insert(id)
        Task {
            await retrace(id)
            retracing.remove(id)
        }
    }

    private func retrace(_ id: UUID) async {
        defer {
            vectorWanted[id] = nil
            vectorPreviewed[id] = nil
            showPreview(Self.vectorPreview, reshaping: nil)
        }
        while let wanted = vectorWanted[id], let (source, version) = vector(of: id), let group = node(id) {
            let draft = inGesture
            if !draft, wanted == version.settings { break }
            let picture = lying(source, version, as: group), pixels = source.pixels
            let made = await Task.detached(priority: .userInitiated) {
                VectorMaker.make(pixels, wanted, draft: draft, replacing: picture)
            }.value
            guard let made, var next = node(id), vector(of: id) != nil else { break }
            // The group as it is now, looking as it does, holding the new layers.
            next.children = made.group.children
            next.frame = made.group.frame
            if draft || inGesture {
                let shown = next
                showPreview(Self.vectorPreview, reshaping: { doc in
                    if let at = doc.path(of: id) { doc[at] = shown }
                })
                vectorPreviewed[id] = (made.shapes, made.colors)
                while inGesture, vectorWanted[id] == wanted { try? await Task.sleep(for: .milliseconds(12)) }
                continue
            }
            showPreview(Self.vectorPreview, reshaping: nil)
            vectorPreviewed[id] = nil
            editApart("Change Vector") { doc in
                if let at = doc.path(of: id) { doc[at] = next }
            }
            if let now = node(id), traced[id] != nil { traced[id]?.remember(now, wanted, shapes: made.shapes, colors: made.colors) }
            if vectorWanted[id] == wanted { break }
        }
    }

    /// Shows a vector's picture in its place, while `on`.
    func showVectorPicture(_ id: UUID, _ on: Bool) {
        guard on, let (source, version) = vector(of: id), let group = node(id) else {
            showPreview("vector-picture", reshaping: nil)
            return
        }
        let picture = lying(source, version, as: group)
        showPreview("vector-picture", reshaping: { doc in
            if let at = doc.path(of: id) { doc[at] = picture }
        })
    }

    /// Puts the picture back in its vector's place.
    func backToPicture(_ id: UUID) {
        guard !isReadOnly, let (source, version) = vector(of: id), let group = node(id) else { return }
        let picture = lying(source, version, as: group)
        showPreview("vector-picture", reshaping: nil)
        edit("Back to Picture") { doc in
            if let at = doc.path(of: id) { doc[at] = picture }
        }
    }
}
