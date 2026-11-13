import Foundation
import CBezzleHost
import Vectorizer
import WinSDK

// From Bezzle/Store/VectorOperations.swift and Canvas/VectorMaker.swift: Vectorize in the open
// design. The picture filling a layer is drawn as it shows, by Skia, read back as pixels and
// traced away from the main thread by the Mac's own engine (Packages/Vectorizer); the group of
// layers the shared model makes of the tracing (Model/Vectorizing.swift) then takes the picture
// layer's place, with its id, in one step of the history. While the design stays open, the group
// remembers its picture: the Vector card traces it again another way, and gives the picture back.
// A drag on the card's dial shows quick tracings as previews and changes the design once, after
// it is let go, as on the Mac.

extension VectorMaker {
    /// The layer as it shows, without its border, shadows, opacity and turn, as pixels: drawn by
    /// the Mac's renderer into a recording, played by Skia, and read back. Nil when it shows no
    /// picture, or nothing at all. On the main thread, where Skia is given what it draws with.
    static func source(of node: Node, assets: Assets) -> Source? {
        guard let (size, scale) = reading(node) else { return nil }
        let first = Images.shared.list.last.map { $0.id + 1 } ?? 0
        guard let ctx = Renderer.bitmap(size) else { return nil }
        let plain = plain(node)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: size.width / node.frame.width, y: -size.height / node.frame.height)
        ctx.interpolationQuality = .high
        Renderer.withFlippedContext(ctx) {
            Renderer.drawNode(plain, in: ctx, options: Renderer.Options(deviceScale: scale, assets: assets))
        }
        guard let made = ctx.makeImage() else { return nil }
        for p in Images.shared.list where p.id >= first { WindowsCore.send(p) }
        defer { WindowsCore.forget(before: first) }
        let w = made.width, h = made.height
        var drawn = [UInt8](repeating: 0, count: w * h * 4)
        let read = drawn.withUnsafeMutableBytes { bz_picture_read(Int32(made.id), Int32(w), Int32(h), 0, $0.baseAddress) }
        guard read == 0, let pixels = drawn.withUnsafeBufferPointer({ straightened($0.baseAddress!, width: w, height: h, rowBytes: w * 4) }) else {
            return nil
        }
        return Source(bitmap: Bitmap(width: w, height: h, pixels: pixels), image: made, scale: size.width / node.frame.width)
    }
}

extension WindowsCore {
    /// A picture being vectorized, as the canvas shows it while it is (the Mac's VectorWork).
    public struct VectorWork {
        /// When it began, on the clock animations run by (`now`).
        public let began = WindowsCore.now
    }

    /// A picture just vectorized, for the canvas to show it turning into shapes (the Mac's
    /// VectorReveal). The Mac keeps the picture as it was drawn; here the layer as it was is drawn
    /// again each frame, as the cutout's drop is.
    public struct VectorReveal {
        /// Where the picture lay on the canvas, and how it was turned.
        let frame: CGRect
        let rotation: Double
        /// The layer as it showed, in its own coordinates (`VectorMaker.plain`).
        let picture: Node
        /// The larger shapes' outlines, in the picture layer's own coordinates.
        let outlines: CGPath
        let at = WindowsCore.now
    }

    /// Why a picture could not be vectorized, in the Mac's words (DocumentStore.VectorTrouble).
    nonisolated enum VectorTrouble: Swift.Error, CustomStringConvertible {
        case noPictures, readOnly, nothing

        /// As an assistant is told it, in English.
        var description: String {
            switch self {
            case .noPictures: "Only a layer filled with a picture can be vectorized."
            case .readOnly: "This design can only be looked at."
            case .nothing: "Nothing was found in the picture to trace."
            }
        }
    }

    // What the open design keeps of Vectorize, as the Mac's store keeps it (each in `visitState`).

    /// Layers whose picture is being made shapes just now.
    public internal(set) static var vectorizing: [Foundation.UUID: VectorWork] = [:]
    /// The pictures vectorized while the design is open, by the group each became.
    static var traced: [Foundation.UUID: VectorSource] = [:]
    /// How a vector is wanted while its picture is traced again, and what the canvas shows of it meanwhile.
    static var vectorWanted: [Foundation.UUID: VectorSettings] = [:]
    static var vectorPreviewed: [Foundation.UUID: (shapes: Int, colors: [RGBA])] = [:]
    /// Pictures just vectorized, for the canvas to show them turning into shapes.
    static var vectorReveals: [Foundation.UUID: VectorReveal] = [:]
    /// The vectors being traced again.
    static var retracing: Set<Foundation.UUID> = []
    /// What shows in a vector's place instead of the design as it is, while it does: a quick
    /// tracing during a drag, or the picture while Picture is held.
    static var vectorShowing: (id: Foundation.UUID, picture: Bool, version: Int)?

    /// What moved on in a design's vectorizing: only the work (the canvas's pencil, the
    /// inspector), what shows in a vector's place without changing the design, or the design.
    public enum VectorChange { case work, shown, edited }

    /// Told, on the main thread, when a design's vectorizing moved on: the window of that design
    /// draws it again.
    nonisolated(unsafe) public static var vectorsChanged: (@MainActor (_ slot: Slot?, _ change: VectorChange) -> Void)?

    /// Whether a layer shows a picture that can become shapes: not one whose place something else
    /// counts on, as the shape of a mask, a copy of a component, a repeat grid's cell or a deck's post.
    public static func vectorizable(_ id: Foundation.UUID) -> Bool {
        design?.vectorizable(id) ?? false
    }

    /// Whether Vectorize is offered for `ids`, as the Mac's canvas menu offers it: any of them a picture that can be.
    public static func canVectorize(_ ids: [Foundation.UUID]) -> Bool {
        !isReadOnly && vectorizing.isEmpty && ids.contains(where: vectorizable)
    }

    /// Whether the inspector offers Vectorize for `ids`, as the Mac's AddBar does: all of them pictures that can be.
    public static func offersVectorize(_ ids: [Foundation.UUID]) -> Bool {
        !isReadOnly && vectorizing.isEmpty && !ids.isEmpty && ids.allSatisfy(vectorizable)
    }

    /// Makes the pictures filling `ids` shapes (the Mac's store.vectorize()), with a beep when
    /// nothing came of it.
    public static func vectorize(_ ids: [Foundation.UUID]) {
        let ids = ids.filter(vectorizable)
        guard !ids.isEmpty, vectorizing.isEmpty else { return }
        Task {
            do { try await vectorize(ids, settings: VectorSettings()) } catch { _ = MessageBeep(UInt32(MB_OK)) }
        }
    }

    /// Makes the pictures filling `ids` shapes: each layer becomes a group of layers, with its id.
    /// Returns those that did. The design is the one in front as it is asked; it may go behind meanwhile.
    @discardableResult
    static func vectorize(_ ids: [Foundation.UUID], settings: VectorSettings) async throws -> [Foundation.UUID] {
        guard !isReadOnly else { throw VectorTrouble.readOnly }
        let slot = active
        guard let doc = design else { throw VectorTrouble.noPictures }
        let pictures = ids.filter { doc.vectorizable($0) }.compactMap { doc.node($0) }
        guard !pictures.isEmpty else { throw VectorTrouble.noPictures }
        for picture in pictures { vectorizing[picture.id] = VectorWork() }
        vectorsChanged?(slot, .work)
        defer {
            vectorWithin(slot) { for picture in pictures { vectorizing[picture.id] = nil } }
            vectorsChanged?(slot, .work)
        }

        // Each drawn as it shows now, here, where Skia is; then traced away from the main thread.
        let read = pictures.compactMap { picture in VectorMaker.source(of: picture, assets: assets).map { (picture, $0) } }
        var made: [(picture: Node, pixels: VectorMaker.Source, made: VectorMaker.Made)] = []
        for (picture, pixels) in read {
            let result = await Task.detached(priority: .userInitiated) { VectorMaker.make(pixels, settings, replacing: picture) }.value
            if let result { made.append((picture, pixels, result)) }
        }
        guard !made.isEmpty else { throw VectorTrouble.nothing }

        // After any drag going on meanwhile, whose steps the change would be lost in.
        while slot?.isOpen ?? true, vectorInGesture(slot) { try? await Task.sleep(for: .milliseconds(100)) }
        var shown: [Foundation.UUID] = []
        vectorWithin(slot) {
            guard let doc = design else { return }
            // Only those still as they were when their picture was read.
            made = made.filter { doc.node($0.picture.id) == $0.picture }
            var next = doc
            var reveals: [Foundation.UUID: VectorReveal] = [:]
            for (picture, _, result) in made {
                guard let at = next.path(of: picture.id), let frame = doc.absoluteFrame(of: picture.id) else { continue }
                // Not `update`, which keeps where each layer is known: a group holds new layers.
                next[at] = result.group
                reveals[picture.id] = VectorReveal(frame: frame, rotation: picture.rotation, picture: VectorMaker.plain(picture), outlines: result.outlines)
            }
            guard next != doc else { return }
            edit { $0 = next }
            for (picture, pixels, result) in made {
                guard let group = design?.node(picture.id), group.kind == .group, !group.children.isEmpty else { continue }
                var source = traced[picture.id].flatMap { $0.picture == picture ? $0 : nil } ?? VectorSource(picture: picture, pixels: pixels)
                source.remember(group, settings, shapes: result.shapes, colors: result.colors)
                traced[picture.id] = source
                vectorReveals[picture.id] = reveals[picture.id]
                shown.append(picture.id)
            }
            forgetVectors(keeping: shown)
        }
        if !shown.isEmpty { vectorsChanged?(slot, .edited) }
        return shown
    }

    /// Pictures are remembered for a few vectors at a time: each holds its pixels.
    private static func forgetVectors(keeping kept: [Foundation.UUID]) {
        for id in Array(traced.keys) where vector(of: id) == nil && !kept.contains(id) && design?.node(id)?.fill.image == nil { traced[id] = nil }
        while traced.count > 6, let other = traced.keys.first(where: { !kept.contains($0) }) { traced[other] = nil }
    }

    // MARK: A vector and its picture

    /// The picture a group of layers was vectorized from, and how, while it is still the layers
    /// that were made of it: moved, resized and looking as it likes, but holding what it held.
    static func vector(of id: Foundation.UUID) -> (source: VectorSource, version: VectorSource.Version)? {
        guard let source = traced[id], let group = (previewBase ?? design)?.node(id), let version = source.version(of: group) else { return nil }
        return (source, version)
    }

    /// Whether `id` is a group made of a picture that it still remembers: the Vector card shows.
    public static func isVector(_ id: Foundation.UUID) -> Bool { vector(of: id) != nil }

    /// How a vector is traced, or is about to be, as the Vector card shows it.
    public struct VectorLook {
        /// How much of the picture's small things the shapes keep, 0…1.
        public let detail: Double
        /// How many colours at most; nil for as many as the picture has.
        public let colors: Int?
        /// The nearest of the outlines' choices (`smoothings`).
        public let smoothing: Double
        /// How many shapes there are and their colours (hex), as the canvas shows them now.
        public let shapes: Int
        public let swatches: [String]
        /// Whether it is being traced again just now.
        public let working: Bool
    }

    /// The choices of how many colours, and of how the outlines run (each with the Mac's key for
    /// its words, and the words in English).
    public static let vectorColorCounts = VectorSettings.colorCounts
    public static let vectorSmoothings: [(value: Double, key: String, english: String)] = VectorSettings.smoothings.map { ($0.value, $0.title.catalogKey, $0.title.key) }

    public static func vectorLook(_ id: Foundation.UUID) -> VectorLook? {
        guard let (_, version) = vector(of: id) else { return nil }
        let settings = vectorWanted[id] ?? version.settings
        let counts = vectorPreviewed[id] ?? (version.shapes, version.colors)
        return VectorLook(detail: settings.detail, colors: settings.colors, smoothing: settings.nearestSmoothing, shapes: counts.shapes,
                          swatches: counts.colors.map(\.hex), working: vectorWanted[id] != nil)
    }

    /// Changes how a vector is traced (detail 0…1, colours, smoothing 0…1, only what is given), and
    /// traces its picture again. During a drag the canvas shows a quick tracing of each amount the
    /// drag passes; once it is let go, the picture is traced in full, and the design changes in one step.
    public static func setVector(_ id: Foundation.UUID, detail: Double? = nil, colors: Int?? = nil, smoothing: Double? = nil) {
        setVector(id) { s in
            if let detail { s.detail = detail }
            if let colors { s.colors = colors }
            if let smoothing { s.smoothing = smoothing }
        }
    }

    static func setVector(_ id: Foundation.UUID, _ change: (inout VectorSettings) -> Void) {
        guard !isReadOnly, let (_, version) = vector(of: id) else { return }
        var wanted = vectorWanted[id] ?? version.settings
        change(&wanted)
        wanted = wanted.held
        guard wanted != (vectorWanted[id] ?? version.settings) else { return }
        vectorWanted[id] = wanted
        guard !retracing.contains(id) else { return }
        retracing.insert(id)
        let slot = active
        Task {
            await retrace(id, in: slot)
            vectorWithin(slot) { retracing.remove(id) }
            // A quick tracing shown last is gone again.
            vectorsChanged?(slot, .shown)
        }
    }

    /// Whether `id` is being traced again just now (an assistant waits for it).
    static func isRetracing(_ id: Foundation.UUID) -> Bool { retracing.contains(id) }

    private static func retrace(_ id: Foundation.UUID, in slot: Slot?) async {
        defer {
            vectorWithin(slot) {
                vectorWanted[id] = nil
                vectorPreviewed[id] = nil
                endVectorPreview(of: id, picture: false)
            }
        }
        while true {
            // What is wanted, and of what, in the design it is wanted in.
            var job: (wanted: VectorSettings, pixels: VectorMaker.Source, picture: Node, draft: Bool)?
            vectorWithin(slot) {
                guard let wanted = vectorWanted[id], let (source, version) = vector(of: id), let group = (previewBase ?? design)?.node(id) else { return }
                let draft = inGesture
                if !draft, wanted == version.settings { return }
                job = (wanted, source.pixels, source.lying(version, as: group), draft)
            }
            guard let job else { return }
            let made = await Task.detached(priority: .userInitiated) {
                VectorMaker.make(job.pixels, job.wanted, draft: job.draft, replacing: job.picture)
            }.value
            guard let made else { return }
            var again = false, over = false
            vectorWithin(slot) {
                guard var next = (previewBase ?? design)?.node(id), vector(of: id) != nil else { over = true; return }
                // The group as it is now, looking as it does, holding the new layers.
                next.children = made.group.children
                next.frame = made.group.frame
                if job.draft || inGesture {
                    showVector(id, next, picture: false)
                    vectorPreviewed[id] = (made.shapes, made.colors)
                    again = true
                    return
                }
                endVectorPreview(of: id, picture: false)
                vectorPreviewed[id] = nil
                edit { doc in
                    if let at = doc.path(of: id) { doc[at] = next }
                }
                if let now = design?.node(id), traced[id] != nil { traced[id]?.remember(now, job.wanted, shapes: made.shapes, colors: made.colors) }
                if vectorWanted[id] == job.wanted { over = true }
            }
            vectorsChanged?(slot, again ? .shown : .edited)
            if over { return }
            if again {
                // Until the drag goes on to another amount, or is let go.
                while true {
                    var waiting = false
                    vectorWithin(slot) { waiting = inGesture && vectorWanted[id] == job.wanted }
                    guard waiting, slot?.isOpen ?? true else { break }
                    try? await Task.sleep(for: .milliseconds(12))
                }
            }
        }
    }

    /// Shows `group` in the vector's place, or the picture (`picture`), without changing the design.
    private static func showVector(_ id: Foundation.UUID, _ shown: Node, picture: Bool) {
        preview { doc in
            if let at = doc.path(of: id) { doc[at] = shown }
        }
        vectorShowing = (id, picture, designVersion)
    }

    /// Whether what `showVector` showed is what shows still: nothing changed the design since,
    /// not another preview, an edit or a change taking every preview away.
    private static var showsVector: Bool {
        guard let showing = vectorShowing else { return false }
        return showing.version == designVersion && previewBase != nil
    }

    /// Takes away what `showVector` showed in the vector's place, when it is that.
    private static func endVectorPreview(of id: Foundation.UUID, picture: Bool) {
        guard let showing = vectorShowing, showing.id == id, showing.picture == picture else { return }
        if showsVector { endPreview() }
        vectorShowing = nil
    }

    /// A drag is given up: a quick tracing shown during it is taken away first, so that it never
    /// becomes part of the design.
    static func endVectorPreviews() {
        if showsVector { endPreview() }
        vectorShowing = nil
    }

    /// `end`, a drag's end, done on the design as it is, without what shows in a vector's place
    /// (which would else be taken for part of the drag); shown again after, until the full
    /// tracing comes as a step of its own.
    static func aroundVectorPreview(_ end: () -> Void) {
        guard let showing = vectorShowing else { end(); return }
        let shown = showsVector ? design?.node(showing.id) : nil
        // Whatever shows in its place goes first: during the dial's drag, nothing else is previewed.
        if previewBase != nil { endPreview() }
        vectorShowing = nil
        end()
        if let shown { showVector(showing.id, shown, picture: showing.picture) }
    }

    /// Shows a vector's picture in its place, while `on` (Picture held on the card).
    public static func showVectorPicture(_ id: Foundation.UUID, _ on: Bool) {
        guard on, let (source, version) = vector(of: id), let group = (previewBase ?? design)?.node(id) else {
            endVectorPreview(of: id, picture: true)
            return
        }
        showVector(id, source.lying(version, as: group), picture: true)
    }

    /// Puts the picture back in its vector's place.
    public static func backToPicture(_ id: Foundation.UUID) {
        guard !isReadOnly else { return }
        endVectorPreview(of: id, picture: true)
        guard let (source, version) = vector(of: id), let group = design?.node(id) else { return }
        let picture = source.lying(version, as: group)
        edit { doc in
            if let at = doc.path(of: id) { doc[at] = picture }
        }
    }

    /// `body` with `slot`'s design as the one worked on, if it is still open; with no slots (a
    /// tool without tabs), as it is.
    private static func vectorWithin(_ slot: Slot?, _ body: () -> Void) {
        guard let slot else { body(); return }
        guard slot.isOpen else { return }
        using(slot, body)
    }

    /// Whether a drag is going on in `slot`'s design.
    private static func vectorInGesture(_ slot: Slot?) -> Bool {
        var dragging = false
        vectorWithin(slot) { dragging = Editing.gestureStart != nil }
        return dragging
    }
}

// MARK: - Trying it without the app

extension WindowsCore {
    /// What `bezzle-render <fonts> vectorize <out>` does: each picture BEZZLE_PICTURES names (separated
    /// by ;) traced as it is, pixel for pixel, by the engine, into `out` as <name>.svg, with what it
    /// found and how long it took; then laid in a layer of BEZZLE_VECTOR_FRAME (w,h; the picture's
    /// size halved when not given) as Vectorize lays it, drawn by Skia as the app draws it, and
    /// made a group, whose layers are listed in <name>-layers.txt as the Mac's ParityTests list
    /// them (`vectorizing`). BEZZLE_DETAIL, BEZZLE_COLORS, BEZZLE_SMOOTHING set it as the card does.
    public static func tryVectors(_ pictures: [URL], into out: URL) -> [String] {
        let environment = ProcessInfo.processInfo.environment
        var settings = VectorSettings()
        if let d = environment["BEZZLE_DETAIL"].flatMap(Double.init) { settings.detail = d / 100 }
        if let c = environment["BEZZLE_COLORS"].flatMap(Int.init) { settings.colors = c }
        if let s = environment["BEZZLE_SMOOTHING"].flatMap(Double.init) { settings.smoothing = s / 100 }
        settings = settings.held
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var said: [String] = []
        for file in pictures {
            let name = file.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: file), let picture = PixelsRead(data) else {
                said.append("\(name): could not be read")
                continue
            }
            // The picture itself, as the engine's own tools trace one.
            let t0 = Date()
            let asked = Settings(colors: settings.colors, detail: settings.detail, smoothing: settings.smoothing)
            guard let tracing = Vectorizer.trace(Bitmap(width: picture.w, height: picture.h, pixels: picture.straight), settings: asked) else {
                said.append("\(name): nothing traced")
                continue
            }
            let took = Date().timeIntervalSince(t0)
            try? tracing.svg().write(to: out.appendingPathComponent("\(name).svg"), atomically: true, encoding: .utf8)
            let points = tracing.shapes.reduce(0) { $0 + $1.outlines.reduce(0) { $0 + 1 + $1.stretches.count } }
            said.append("\(name): \(picture.w)x\(picture.h), \(tracing.shapes.count) shapes, \(tracing.palette.count) colours, \(points) points, \(String(format: "%.3f", took)) s")

            // As a layer in a design, read by Skia and made a group, as the app does it.
            let size: CGSize = {
                let wh = environment["BEZZLE_VECTOR_FRAME"]?.split(separator: ",").compactMap { Double($0) } ?? []
                return wh.count == 2 ? CGSize(width: wh[0], height: wh[1]) : CGSize(width: Double(picture.w) / 4, height: Double(picture.h) / 4)
            }()
            let asset = "vector-\(name).png"
            giveSkia(asset, data)
            var layer = Node(kind: .rectangle, name: "Photo", frame: CGRect(x: 50, y: 50, width: size.width, height: size.height))
            layer.fill = Fill(color: .shape, image: ImageFill(asset: asset, size: CGSize(width: picture.w, height: picture.h)))
            if let turn = environment["BEZZLE_VECTOR_TURN"].flatMap(Double.init) {
                layer.kind = .ellipse
                layer.rotation = turn
                layer.opacity = 0.8
            }
            let t1 = Date()
            guard let source = VectorMaker.source(of: layer, assets: Assets(folder: nil)) else {
                said.append("\(name): the layer showed nothing")
                continue
            }
            let read = Date().timeIntervalSince(t1)
            guard let made = VectorMaker.make(source, settings, replacing: layer) else {
                said.append("\(name): the layer made no shapes")
                continue
            }
            var doc = BezzleDocument()
            var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: size.width + 100, height: size.height + 100))
            board.children = [made.group]
            doc.nodes = [board]
            doc.fitGroups()
            let group = doc.nodes[0].children[0]
            func n(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }
            func r(_ f: CGRect?) -> String { f.map { "\(n($0.minX)),\(n($0.minY)) \(n($0.width))x\(n($0.height))" } ?? "nil" }
            func hash(_ bytes: some Sequence<UInt8>) -> String {
                var h: UInt64 = 0xcbf29ce484222325
                for b in bytes { h = (h ^ UInt64(b)) &* 0x100000001b3 }
                return String(h, radix: 16)
            }
            var lines = ["\(name) read: \(source.bitmap.width)x\(source.bitmap.height) scale \(n(source.scale)) pixels \(hash(source.bitmap.pixels)) in \(String(format: "%.3f", read)) s",
                         "\(name): \(group.kind) \(group.name) \(r(group.frame)) turn \(n(CGFloat(group.rotation))) opacity \(n(CGFloat(group.opacity))) "
                             + "layers \(group.children.count) shapes \(made.shapes) colours \(made.colors.map(\.hex).joined(separator: ","))"]
            for (i, c) in group.children.enumerated() {
                lines.append("\(name) \(i): \(c.kind) \(r(c.frame)) turn \(n(CGFloat(c.rotation))) \(c.fill.color.hex) corner \(n(c.cornerRadius)) "
                    + "path \(c.path.map { "\($0.count) \(hash($0.utf8))" } ?? "-") box \(r(c.pathBox))")
            }
            try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("\(name)-layers.txt"), atomically: true, encoding: .utf8)
            said.append("\(name): as a layer \(n(size.width))x\(n(size.height)), read at \(source.bitmap.width)x\(source.bitmap.height), \(group.children.count) layers")
        }
        return said
    }

    /// A picture file's pixels in sRGB, colours not multiplied by how solid they are, rows top
    /// first: read by Skia at its own size, upright.
    private struct PixelsRead {
        let w: Int, h: Int
        let straight: [UInt8]

        init?(_ data: Data) {
            var w: Int32 = 0, h: Int32 = 0
            guard data.withUnsafeBytes({ bz_image_size($0.baseAddress, Int32(clamping: $0.count), &w, &h) }) != 0, w > 0, h > 0 else { return nil }
            let longest = Int(max(w, h))
            var bytes = [UInt8](repeating: 0, count: longest * longest * 4)
            let read = data.withUnsafeBytes { d in
                bytes.withUnsafeMutableBytes { bz_image_thumbnail(d.baseAddress, Int64(d.count), Int32(longest), &w, &h, $0.baseAddress) }
            }
            guard read != 0, w > 0, h > 0,
                  let straight = bytes.withUnsafeBufferPointer({ VectorMaker.straightened($0.baseAddress!, width: Int(w), height: Int(h), rowBytes: Int(w) * 4) })
            else { return nil }
            self.w = Int(w)
            self.h = Int(h)
            self.straight = straight
        }
    }
}
