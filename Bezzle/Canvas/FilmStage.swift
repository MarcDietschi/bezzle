import AppKit
import CoreImage

/// The film's stage, in Animate: the artboard being animated, shown as its pieces' pictures
/// (`FilmPictures`), each placed where the camera shows it at the playhead (`FilmLens`). Pictures
/// are drawn once, away from here, and after that the graphics card only moves them, so posing a
/// layer, scrubbing and playing all keep to the screen's own frames however much is on the artboard.
///
/// It lies under the canvas, which cuts a window over the artboard to show it. So everything the
/// canvas draws over the design, the handles and the motion's path, is drawn over the film as
/// over any artboard, in the same frame.
final class FilmStageView: NSView {
    private let store: DocumentStore

    /// Laid out from the top, as the canvas is.
    private let content = CALayer()
    /// The film's frame on screen: what is past it is cut off, and the backdrop shows in it.
    private let gate = CALayer()
    /// The artboard's own points, scaled to the frame.
    private let scene = CALayer()

    /// A piece on the stage: its picture's layer, and what it was drawn from.
    private struct Shown {
        var piece: FilmPiece
        var subject: FilmPictures.Subject
        var rect: CGRect
        var layer: CALayer
        var blurred = false
    }

    /// A piece to put on the stage, and what its picture has to show.
    private struct Wanted: Sendable {
        var piece: FilmPiece
        var subject: FilmPictures.Subject
    }

    /// A picture to draw.
    private struct Job: Sendable {
        var key: String
        var subject: FilmPictures.Subject
        var scale: CGFloat
    }

    /// A picture kept: what it shows, how sharp, and when it was last on the stage.
    private struct Kept {
        var subject: FilmPictures.Subject
        var scale: CGFloat
        var picture: FilmPictures.Picture
        var used: Int
    }

    /// What the pieces on the stage were worked out from, to tell when to work them out again.
    private struct Signature: Equatable {
        var version: Int
        var board: UUID
        var loose: Set<UUID>
        var fronts: [UUID: Int]
        var step: CGFloat
    }

    private var shown: [Shown] = []
    private var shownBoard: UUID?
    private var order: [Int] = []
    private var kept: [String: Kept] = [:]
    /// The artboard the pictures are drawn on, the same one for as long as nothing of it changes.
    private var ground: FilmPictures.Ground?
    private var signature: Signature?
    /// The moment the pieces whose insides move were last drawn for.
    private var drawnAt = -1.0
    private var changing = false
    /// Counts the sets of pictures asked for, so one that comes after a newer was asked for is dropped.
    private var generation = 0
    private var installs = 0
    private var making = false
    private var link: CADisplayLink?
    private static let queue = DispatchQueue(label: "Bezzle film pictures", qos: .userInteractive)

    init(store: DocumentStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layerUsesCoreImageFilters = true
        gate.masksToBounds = true
        gate.isHidden = true
        scene.anchorPoint = .zero
        gate.addSublayer(scene)
        content.addSublayer(gate)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard let layer else { return }
        if content.superlayer == nil { layer.addSublayer(content) }
        // Laid out from the top, as the canvas is. Each layer above that flips its own turns
        // everything in it over once more, so the content flips only when they come out even.
        var flips = 0
        var above: CALayer? = layer
        while let l = above {
            if l.isGeometryFlipped { flips += 1 }
            above = l.superlayer
        }
        Self.still {
            content.isGeometryFlipped = flips % 2 == 0
            content.frame = bounds
        }
    }

    /// How sharp to draw for something shown this many times its size: the next of the steps
    /// that double it every second one. What is a hair over a step, as a layer that is only turned
    /// comes out of the arithmetic, keeps to that step, and is not drawn half as sharp again.
    private static func sharpness(for times: CGFloat) -> CGFloat {
        pow(2, (log2(times) * 2 - 0.02).rounded(.up) / 2)
    }

    private static func still(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: Following the design

    /// Brings the stage to the design, the playhead and the view as they are now. Gives back the
    /// part of the canvas, in its points, that the film covers, for the canvas to cut its window
    /// there; nil while there is no film to show, or its first pictures are still being drawn.
    func sync(scale: CGFloat) -> CGRect? {
        guard store.animating, let board = store.filmBoard, bounds.width > 0, board.frame.width > 0, board.frame.height > 0 else {
            hide()
            return nil
        }
        let zoom = store.viewport.zoom
        let raw = store.viewport.toView(board.frame)
        // On whole pixels, so the window and the film meet without a seam.
        let rect = CGRect(x: (raw.minX * scale).rounded() / scale, y: (raw.minY * scale).rounded() / scale,
                          width: max(1, (raw.width * scale).rounded()) / scale, height: max(1, (raw.height * scale).rounded()) / scale)
        // Sharp for the zoom, in steps, so that zooming draws them again only now and then.
        let step = Self.sharpness(for: max(zoom * scale, 0.05))
        // While it plays, the moment is read where the canvas does not watch it, or the whole canvas
        // would be drawn again each frame.
        let t = store.film.playing ? store.film.head : store.filmTime
        let wanted = Signature(version: store.version, board: board.id, loose: Set(store.posedLayers), fronts: store.fronts, step: step)
        if wanted != signature {
            signature = wanted
            prepare(board, at: t, pixels: step)
        } else if changing, t != drawnAt, !making {
            prepare(board, at: t, pixels: step, again: true)
        }
        guard shownBoard == board.id, !shown.isEmpty else {
            Self.still { gate.isHidden = true }
            return nil
        }
        Self.still {
            gate.isHidden = false
            gate.frame = rect
            // As the movie has it: a backdrop that is not solid lies on black.
            let backdrop = board.filmBackdrop
            gate.backgroundColor = RGBA(r: backdrop.r * backdrop.a, g: backdrop.g * backdrop.a, b: backdrop.b * backdrop.a).cgColor
            scene.bounds = CGRect(origin: .zero, size: board.frame.size)
            scene.position = .zero
            scene.transform = CATransform3DMakeScale(rect.width / board.frame.width, rect.height / board.frame.height, 1)
            place(board, at: t, pixels: zoom * scale)
        }
        // A film that plays while its stage was put away goes on now that it shows.
        if store.film.playing { run() }
        return rect
    }

    private func hide() {
        guard signature != nil || shownBoard != nil else { return }
        signature = nil
        shownBoard = nil
        shown = []
        order = []
        kept = [:]
        ground = nil
        generation += 1
        making = false
        stop()
        // A film whose artboard is gone has stopped, which the next frame would have told the desk.
        if store.film.playing, store.filmBoard == nil { _ = store.filmStep(CACurrentMediaTime()) }
        Self.still {
            gate.isHidden = true
            scene.sublayers = nil
        }
    }

    /// Works out the film's pieces, and has the pictures drawn that are not kept from before.
    /// The pieces shown stay until every picture of the new ones has come, so nothing flickers.
    ///
    /// `again` when only time has passed since they were last worked out, for the pieces whose
    /// insides move: the others are left as they are, and nothing is measured anew, so a film
    /// with such a piece among hundreds still plays at the screen's pace.
    private func prepare(_ board: Node, at t: Double, pixels: CGFloat, again: Bool = false) {
        let pieces = board.filmPieces(loose: Set(store.posedLayers))
        changing = pieces.contains(where: \.changes)
        drawnAt = t
        // One ground for all the pieces, and the one from before while the artboard is as it was.
        let ground: FilmPictures.Ground
        if again, let had = self.ground { ground = had } else { ground = FilmPictures.Ground.of(board, before: self.ground) }
        self.ground = ground
        var set: [(piece: FilmPiece, subject: FilmPictures.Subject, scale: CGFloat)] = []
        var missing: [Job] = []
        // While a layer is being dragged, how large it will ever show is not asked again each step.
        let measured = !store.inGesture && !again
        for piece in pieces {
            let had = kept[piece.key]
            if again, !piece.changes, let had {
                set.append((piece, had.subject, had.scale))
                continue
            }
            let subject = FilmPictures.subject(of: piece, on: board, ground: ground, at: t)
            let rect = FilmPictures.rect(of: subject)
            guard rect.width > 0, rect.height > 0 else { continue }
            var scale = pixels
            if measured || had == nil {
                // Sharp at its largest in the whole film, within reason.
                scale = pixels * Self.sharpness(for: min(board.filmStretch(of: piece, around: rect), 4))
            } else if let had {
                scale = had.scale
            }
            scale = min(scale, FilmPictures.most / max(rect.width, rect.height))
            set.append((piece, subject, scale))
            if let had, had.scale >= scale * 0.99, had.subject.isDrawn(as: subject) { continue }
            missing.append(Job(key: piece.key, subject: subject, scale: scale))
        }
        generation += 1
        let mine = generation, id = board.id
        let wanted = set.map { Wanted(piece: $0.piece, subject: $0.subject) }
        guard !missing.isEmpty else {
            install(wanted, board: id)
            return
        }
        making = true
        let assets = store.assets
        let jobs = missing
        Self.queue.async {
            let made = FilmMade()
            DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
                made.put(jobs[i].key, FilmPictures.picture(of: jobs[i].subject, scale: jobs[i].scale, assets: assets))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // The pictures are kept even when a newer set was asked for meanwhile: most of
                    // them are the newer set's too.
                    for job in jobs {
                        guard let picture = made.all[job.key] else { continue }
                        self.kept[job.key] = Kept(subject: job.subject, scale: job.scale, picture: picture, used: self.installs)
                    }
                    #if DEBUG
                    self.picturesMade += jobs.count
                    #endif
                    self.making = false
                    guard mine == self.generation else {
                        // Asked again with what there is now.
                        self.signature = nil
                        self.store.canvas?.needsDisplay = true
                        return
                    }
                    self.install(wanted, board: id)
                    self.store.canvas?.needsDisplay = true
                }
            }
        }
    }

    /// Puts a set of pieces on the stage, each with the picture kept for it.
    private func install(_ set: [Wanted], board: UUID) {
        installs += 1
        var layers: [String: CALayer] = [:]
        // A layer that is kept keeps its blur, to be taken off again when its piece is sharp.
        var blurred: Set<String> = []
        for s in shown {
            layers[s.piece.key] = s.layer
            if s.blurred { blurred.insert(s.piece.key) }
        }
        var next: [Shown] = []
        Self.still {
            for item in set {
                guard var had = kept[item.piece.key] else { continue }
                had.used = installs
                kept[item.piece.key] = had
                let layer = layers.removeValue(forKey: item.piece.key) ?? Self.pictureLayer()
                if layer.contents as AnyObject? !== had.picture.image { layer.contents = had.picture.image }
                layer.bounds = had.picture.rect
                next.append(Shown(piece: item.piece, subject: item.subject, rect: had.picture.rect, layer: layer,
                                  blurred: blurred.contains(item.piece.key)))
            }
            for (_, old) in layers { old.removeFromSuperlayer() }
            scene.sublayers = next.map(\.layer)
        }
        shown = next
        order = Array(next.indices)
        shownBoard = board
        // Pictures not on the stage for a while are let go.
        kept = kept.filter { $0.value.used >= installs - 3 }
    }

    private static func pictureLayer() -> CALayer {
        let l = CALayer()
        l.anchorPoint = .zero
        l.position = .zero
        l.contentsGravity = .resize
        l.allowsEdgeAntialiasing = true
        l.minificationFilter = .trilinear
        l.magnificationFilter = .linear
        return l
    }

    // MARK: Placing

    /// Places every piece where the camera shows it at a moment.
    private func place(_ board: Node, at t: Double, pixels: CGFloat) {
        guard !shown.isEmpty else { return }
        let camera = board.camera(at: t)
        let pieces = shown.map(\.piece)
        let placements = pieces.map { board.placement(of: $0, at: t, camera: camera) }
        let wanted = board.filmOrder(pieces, placements)
        if wanted != order {
            order = wanted
            scene.sublayers = wanted.map { shown[$0].layer }
        }
        for i in shown.indices {
            let p = placements[i], layer = shown[i].layer
            let map = p.map.after(.translation(Double(shown[i].rect.minX), Double(shown[i].rect.minY)))
            var m = CATransform3DIdentity
            m.m11 = map.a; m.m21 = map.b; m.m41 = map.c
            m.m12 = map.d; m.m22 = map.e; m.m42 = map.f
            m.m14 = map.g; m.m24 = map.h; m.m44 = map.i
            layer.transform = m
            layer.opacity = Float(p.opacity)
            // Wholly behind the eye, nothing of it shows, in the movie neither.
            let r = shown[i].rect
            let behind = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
                .allSatisfy { p.map.depth(at: $0) <= 1e-3 }
            if layer.isHidden != behind { layer.isHidden = behind }
            if p.blur > 0.05 {
                if !shown[i].blurred {
                    shown[i].blurred = true
                    if let blur = CIFilter(name: "CIGaussianBlur") {
                        blur.name = "blur"
                        layer.filters = [blur]
                    }
                }
                layer.setValue(p.blur * Double(pixels), forKeyPath: "filters.blur.inputRadius")
            } else if shown[i].blurred {
                shown[i].blurred = false
                layer.filters = nil
            }
        }
    }

    // MARK: Playing

    /// Runs the film for as long as it plays: each frame of the screen places the pictures anew.
    func run() {
        guard link == nil, window != nil else { return }
        let l = displayLink(target: self, selector: #selector(step))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ l: CADisplayLink) {
        advance(to: l.targetTimestamp)
    }

    /// One frame of the screen: moves the film on to `now`, and places its pictures there. The
    /// film's run ends with the frame that finds it stopped.
    func advance(to now: CFTimeInterval) {
        guard store.filmStep(now), let board = store.filmBoard, shownBoard == board.id else {
            if !store.film.playing { stop() }
            return
        }
        let t = store.film.head
        Self.still { place(board, at: t, pixels: store.viewport.zoom * (window?.backingScaleFactor ?? 2)) }
        // Pieces whose insides move are drawn again as it goes, as fast as they can be.
        if changing, !making, t != drawnAt, let signature {
            prepare(board, at: t, pixels: signature.step, again: signature.version == store.version)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        if window == nil { stop() } else if store.film.playing { run() }
    }

    #if DEBUG
    // For the tests, which drive the stage without a window and wait for its pictures.

    /// How many pictures have been drawn since the stage was made.
    private(set) var picturesMade = 0
    /// Whether pictures are being drawn right now, away from here.
    var isDrawing: Bool { making }
    /// Whether the film runs: each frame of the screen moves it on.
    var isRunning: Bool { link != nil }
    #endif

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        needsLayout = true
    }
}

/// Pictures made on several threads at once, gathered.
private final class FilmMade: @unchecked Sendable {
    private let lock = NSLock()
    private var pictures: [String: FilmPictures.Picture] = [:]

    func put(_ key: String, _ picture: FilmPictures.Picture?) {
        guard let picture else { return }
        lock.lock()
        pictures[key] = picture
        lock.unlock()
    }

    var all: [String: FilmPictures.Picture] {
        lock.lock()
        defer { lock.unlock() }
        return pictures
    }
}
