import AppKit
import CoreImage
import CoreVideo
import IOSurface

/// The film's stage, in Animate: the artboard being animated, shown as its pieces' pictures
/// (`FilmPictures`), each placed where the camera shows it at the playhead (`FilmLens`). Pictures
/// are drawn once, away from here, and after that the graphics card only moves them, so posing a
/// layer, scrubbing and playing all keep to the screen's own frames however much is on the artboard.
///
/// A design is shapes and letters, and stays sharp however near the camera or the view goes: a
/// piece that shows larger than its picture holds has the part of it that is seen drawn again,
/// as sharp as it is seen, and laid over the picture (`sharpen`). Its whole picture stays under
/// what that part does not cover, so there is always something to show while a part is drawn.
///
/// It lies under the canvas, which cuts a window over the artboard to show it. So everything the
/// canvas draws over the design, the handles and the motion's path, is drawn over the film as
/// over any artboard, in the same frame.
///
/// Under a camera that blurs what stands off its focus (`FilmPlacement.soft`) the pictures are
/// not moved by the graphics card's layers, which can blur a layer by one amount only and
/// before it is tipped: the film's frame is put together as a movie's is (`FilmExport.composed`),
/// of the same pictures in the same places, and shown in one layer over the others (`focus`).
/// That is made away from here too, one frame at a time and always the newest asked for, so the
/// playhead is never kept waiting for it. A film with nothing blurred never comes there.
final class FilmStageView: NSView {
    private let store: DocumentStore

    /// Laid out from the top, as the canvas is.
    private let content = CALayer()
    /// The film's frame on screen: what is past it is cut off, and the backdrop shows in it.
    private let gate = CALayer()
    /// The artboard's own points, scaled to the frame.
    private let scene = CALayer()
    /// The film's frame as a camera that blurs shows it, over the scene, which is hidden meanwhile.
    private let lens = CALayer()

    /// A piece on the stage: its whole picture's layer, and what it was drawn from.
    private struct Shown {
        var piece: FilmPiece
        var subject: FilmPictures.Subject
        /// What its whole picture covers, and where it draws at all, which reaches further when
        /// something of it lies far outside the artboard.
        var rect: CGRect
        var reach: CGRect
        var layer: CALayer
        /// Its whole picture.
        var picture: FilmPictures.Picture
        /// How many pixels to the point its whole picture has.
        var sharp: CGFloat
        var blurred = false
        /// The part drawn sharper, in a layer of its own right over the whole picture's and
        /// placed as that is, while one is shown; which part; and its picture.
        var over: CALayer?
        var part: FilmPictures.Part?
        var overPicture: FilmPictures.Picture?
    }

    /// A part of a piece drawn sharper than its whole picture: what it shows, and its picture.
    private struct Sharper {
        var subject: FilmPictures.Subject
        var part: FilmPictures.Part
        var picture: FilmPictures.Picture
    }

    /// A part to draw.
    private struct PartJob: Sendable {
        var key: String
        var subject: FilmPictures.Subject
        var part: FilmPictures.Part
    }

    /// A piece to put on the stage, and what its picture has to show.
    private struct Wanted: Sendable {
        var piece: FilmPiece
        var subject: FilmPictures.Subject
    }

    /// A picture to draw: of all of a piece, or for a piece whose insides move, of the part of
    /// it that shows.
    private struct Job: Sendable {
        var key: String
        var subject: FilmPictures.Subject
        var scale: CGFloat
        var part: FilmPictures.Part? = nil
    }

    /// A picture kept: what it shows, how sharp, of which part when not of all of it, and when
    /// it was last on the stage.
    private struct Kept {
        var subject: FilmPictures.Subject
        var scale: CGFloat
        var part: FilmPictures.Part? = nil
        var picture: FilmPictures.Picture
        /// Where its subject draws at all and what the picture covers, measured as it was drawn.
        var reach: CGRect
        var used: Int
    }

    /// The screen's colours, handed to the threads that draw.
    private struct Space: @unchecked Sendable {
        let space: CGColorSpace?
    }

    /// What the pieces on the stage were worked out from, to tell when to work them out again.
    private struct Signature: Equatable {
        var version: Int
        var board: UUID
        var loose: Set<UUID>
        var fronts: [UUID: Int]
        var step: CGFloat
        /// Whether how large each piece shows in the whole film was asked, which it is not while
        /// something is dragged. So the pieces are worked out once more when the drag ends: a
        /// camera brought closer by a drag would leave its pictures as sharp as they were before.
        var measured: Bool
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
    private var zoomSettled: DispatchWorkItem?
    /// How long a zoom by hand stays put before the pictures are made as sharp as it wants. A zoom
    /// from the menu, a key or a glide is drawn sharp at once.
    private static let zoomSettles: CFTimeInterval = 0.15

    /// The canvas, and with it the stage, is drawn again once the zoom has stayed put.
    private func drawWhenZoomSettles() {
        zoomSettled?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.zoomSettled = nil
            self?.store.canvas?.needsDisplay = true
        }
        zoomSettled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.zoomSettles + 0.02, execute: work)
    }

    /// How large each piece shows at most in the whole film, by its key, for the design as it was.
    private var stretches: (version: Int, board: UUID, fronts: [UUID: Int], loose: Set<UUID>, of: [String: (rect: CGRect, stretch: Double)])?
    private var installs = 0
    private var making = false
    /// The parts drawn sharper, by their piece; whether some are being drawn now; and a count
    /// that tells parts asked for before the stage was put away from those asked for since.
    private var sharper: [String: Sharper] = [:]
    private var sharpening = false
    private var sharpRound = 0
    /// While it plays, the frames since it last looked ahead for parts to draw.
    private var sinceAhead = 0
    /// The layer each piece on the stage places, found once for each design and set of pieces,
    /// and not looked for through the whole artboard at every frame.
    private var placing: (version: Int, fronts: [UUID: Int], board: UUID, pieces: [FilmPiece], layers: [Node?])?
    /// The colours of the screen the stage is on, which its pictures are drawn in; nil away from
    /// a window, which draws them in sRGB.
    private var space: CGColorSpace?
    /// The screen's pixels to the artboard's point, as the stage was last brought to the design.
    private var screen: CGFloat = 0
    private var link: CADisplayLink?
    private static let queue = DispatchQueue(label: "Bezzle film pictures", qos: .userInteractive)

    /// What the lens was last asked to show; whether a frame of it is being made, and the
    /// newest asked for meanwhile, which is made next; and a count that tells frames asked for
    /// before the lens was put away from those asked for since.
    private var lensAsked: LensLook?
    private var lensing = false
    private var lensNext: LensJob?
    private var lensRound = 0
    /// The picture the lens shows, and the part of the artboard it covers, in the artboard's
    /// points from its top left.
    private var lensShown: (surface: IOSurface, covers: CGRect, board: CGSize)?
    /// The pictures the lens's frames are made in, by turns, so that none is written to while
    /// the screen still shows it.
    private var surfaces: [IOSurface] = []
    private var turn = 0
    /// The pieces' pictures as Core Image takes them, each made once.
    private var stills: [ObjectIdentifier: (image: CGImage, still: FilmExport.Still)] = [:]
    private static let lensQueue = DispatchQueue(label: "Bezzle film lens", qos: .userInteractive)

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
        lens.name = Self.lensName
        lens.anchorPoint = .zero
        lens.contentsGravity = .resize
        lens.isOpaque = true
        lens.isHidden = true
        gate.addSublayer(lens)
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
        Self.still { content.frame = bounds }
        layFromTheTop()
    }

    /// Lays the content out from the top, as the canvas is. Each layer above that flips its own
    /// turns everything in it over once more, so the content flips only when they come out even.
    ///
    /// Asked every time the stage is brought to the design, not only when it is laid out: the
    /// layers above are hung into one another, and told which way up they lie, when the window
    /// first shows them, which is after the first layout. Found once at layout, a design opened
    /// in a window that was never resized had its film upside down: every piece upright but at the
    /// mirrored place, so it moved against the scroll and a layer picked jumped across the artboard.
    private func layFromTheTop() {
        guard let layer else { return }
        var flips = 0
        var above: CALayer? = layer
        while let l = above {
            if l.isGeometryFlipped { flips += 1 }
            above = l.superlayer
        }
        let turned = flips % 2 == 0
        if content.isGeometryFlipped != turned { Self.still { content.isGeometryFlipped = turned } }
    }

    /// How sharp to draw for something shown this many times its size: the next of the steps
    /// that double it every second one. What is a hair over a step, as a layer that is only turned
    /// comes out of the arithmetic, keeps to that step, and is not drawn half as sharp again.
    private static func sharpness(for times: CGFloat) -> CGFloat {
        pow(2, (log2(times) * 2 - 0.02).rounded(.up) / 2)
    }

    private static func same(_ a: CGColorSpace?, _ b: CGColorSpace?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): a === b || CFEqual(a, b)
        default: false
        }
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
        // Drawn in the screen's own colours; on another screen, all of them again.
        let space = window?.colorSpace?.cgColorSpace
        if !Self.same(space, self.space) {
            self.space = space
            kept = [:]
            sharper = [:]
            sharpRound += 1
            signature = nil
            surfaces = []
            stills = [:]
        }
        screen = zoom * scale
        let wanted = Signature(version: store.version, board: board.id, loose: Set(store.posedLayers), fronts: store.fronts, step: step,
                               measured: !store.inGesture)
        // Zoomed by hand a moment ago, with a pinch or the wheel, and so likely to go on.
        let pinching = CACurrentMediaTime() - (store.canvas?.zoomedByHand ?? -.infinity) < Self.zoomSettles
        if wanted != signature {
            var sharper = wanted
            sharper.step = signature?.step ?? step
            if pinching, sharper == signature {
                // Only how sharp they are wanted, while a hand zooms:
                // the pictures there are, stretched, show meanwhile, and are drawn anew once it
                // has stayed put a moment, as the tiles are. Drawn anew at every step of
                // sharpness, the pieces were worked out again on the main thread several times
                // a second while zooming in and out.
                drawWhenZoomSettles()
            } else {
                signature = wanted
                prepare(board, at: t, pixels: step, frame: rect)
            }
        } else if changing, t != drawnAt, !making {
            prepare(board, at: t, pixels: step, frame: rect, again: true)
        }
        guard shownBoard == board.id, !shown.isEmpty else {
            Self.still { gate.isHidden = true }
            return nil
        }
        layFromTheTop()
        Self.still {
            gate.isHidden = false
            gate.frame = rect
            // As the movie has it: a backdrop that is not solid lies on black.
            let backdrop = board.filmBackdrop
            gate.backgroundColor = RGBA(r: backdrop.r * backdrop.a, g: backdrop.g * backdrop.a, b: backdrop.b * backdrop.a).cgColor
            scene.bounds = CGRect(origin: .zero, size: board.frame.size)
            scene.position = .zero
            scene.transform = CATransform3DMakeScale(rect.width / board.frame.width, rect.height / board.frame.height, 1)
            // What the lens shows stays on the artboard while the view moves, until its next frame comes.
            fitLens()
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
        sharper = [:]
        sharpRound += 1
        ground = nil
        generation += 1
        making = false
        stop()
        unlens()
        surfaces = []
        stills = [:]
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
    ///
    /// A piece whose insides move is drawn again at every moment, so it is drawn only as it is
    /// seen then: the part of it that shows through the film's frame on the screen (`frame`, in
    /// the view's points), as sharp as it shows there, with a little room round it for a camera on
    /// its way. All of it, as sharp as it ever shows, would be drawn again at every moment too,
    /// and a large piece, such as a shader under the whole artboard, would fall behind the playhead.
    /// How large a piece shows at most in the whole film (`Node.filmStretch`, which looks at
    /// a hundred moments of it). That changes with the design alone, so it is kept until the
    /// design changes: asked again for every piece whenever zooming crossed a step of sharpness,
    /// it held the canvas up several times a second while zooming in and out.
    private func stretch(of piece: FilmPiece, around rect: CGRect, on board: Node) -> Double {
        let loose = Set(store.posedLayers)
        if let had = stretches, had.version == store.version, had.board == board.id, had.fronts == store.fronts, had.loose == loose {
            if let found = had.of[piece.key], found.rect == rect { return found.stretch }
        } else {
            stretches = (store.version, board.id, store.fronts, loose, [:])
        }
        let found = board.filmStretch(of: piece, around: rect)
        stretches?.of[piece.key] = (rect, found)
        return found
    }

    private func prepare(_ board: Node, at t: Double, pixels: CGFloat, frame: CGRect? = nil, again: Bool = false) {
        let pieces = board.filmPieces(loose: Set(store.posedLayers))
        changing = pieces.contains(where: \.changes)
        drawnAt = t
        let seen = window(of: board, frame: frame)
        var lens: (camera: FilmCamera, layers: [Node?])?
        // One ground for all the pieces, and the one from before while the artboard is as it was.
        let ground: FilmPictures.Ground
        if again, let had = self.ground { ground = had } else { ground = FilmPictures.Ground.of(board, before: self.ground) }
        self.ground = ground
        var set: [(piece: FilmPiece, subject: FilmPictures.Subject, scale: CGFloat)] = []
        var missing: [Job] = []
        // While a layer is being dragged, how large it will ever show is not asked again each step.
        let measured = !store.inGesture && !again
        for (index, piece) in pieces.enumerated() {
            let had = kept[piece.key]
            if again, !piece.changes, let had {
                set.append((piece, had.subject, had.scale))
                continue
            }
            let subject = FilmPictures.subject(of: piece, on: board, ground: ground, at: t)
            // What its whole picture is made of; the rest of it, far outside the artboard, is
            // drawn when the camera finds it.
            let rect = FilmPictures.core(of: subject)
            guard rect.width > 0, rect.height > 0 else { continue }
            if piece.changes, seen.width > 0, screen > 0 {
                let found = lens ?? (board.camera(at: t), board.filmLayers(of: pieces))
                lens = found
                if let part = Self.seenPart(of: subject, placed: board.placement(of: piece, layer: found.layers[index], at: t, camera: found.camera),
                                            through: seen, screen: screen) {
                    set.append((piece, subject, part.scale))
                    if let had, had.subject.isDrawn(as: subject), Self.holds(had, part) { continue }
                    missing.append(Job(key: piece.key, subject: subject, scale: part.scale, part: part))
                    continue
                }
            }
            var scale = pixels
            if measured || had == nil {
                // Sharp at its largest in the whole film, within reason.
                scale = pixels * Self.sharpness(for: min(stretch(of: piece, around: rect, on: board), 4))
            } else if let had {
                scale = had.scale
            }
            scale = min(scale, FilmPictures.most / max(rect.width, rect.height))
            set.append((piece, subject, scale))
            if let had, had.part == nil, had.scale >= scale * 0.99, had.subject.isDrawn(as: subject) { continue }
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
        let assets = store.assets, space = Space(space: space)
        let jobs = missing
        Self.queue.async {
            let made = FilmMade()
            DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
                let picture = FilmPictures.picture(of: jobs[i].subject, scale: jobs[i].scale, assets: assets, part: jobs[i].part, space: space.space)
                made.put(jobs[i].key, picture, reach: picture.map { FilmPictures.rect(of: jobs[i].subject).union($0.rect) } ?? .null)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // The pictures are kept even when a newer set was asked for meanwhile: most of
                    // them are the newer set's too.
                    let all = made.all, reaches = made.reaches
                    for job in jobs {
                        guard let picture = all[job.key] else { continue }
                        self.kept[job.key] = Kept(subject: job.subject, scale: job.scale, part: job.part, picture: picture,
                                                  reach: reaches[job.key] ?? picture.rect, used: self.installs)
                    }
                    #if DEBUG
                    self.picturesMade += jobs.count
                    #endif
                    self.making = false
                    guard mine == self.generation else {
                        // Asked again with what there is now.
                        self.signature = nil
                        self.store.canvas?.redrawForArrivals()
                        return
                    }
                    let showing = self.shownBoard == id && !self.gate.isHidden
                    self.install(wanted, board: id)
                    self.placeNew(showing: showing)
                }
            }
        }
    }

    /// The part to draw of a piece whose insides move, placed so at the moment: what shows of it
    /// through `window`, as sharp as it shows at `screen` pixels to the artboard's point, and a
    /// tenth more each way. Nil for one that does not show, or shows blurred: that is drawn whole.
    private static func seenPart(of subject: FilmPictures.Subject, placed p: FilmPlacement, through window: CGRect, screen: CGFloat) -> FilmPictures.Part? {
        let reach = FilmPictures.rect(of: subject)
        guard p.blur <= 0.05, p.opacity > 0.001, reach.width > 0, reach.height > 0, let seen = p.map.seen(of: reach, through: window) else { return nil }
        let need = CGFloat(seen.stretch) * screen
        return FilmPictures.part(for: seen.part, of: reach, need: need, margin: 0.1, around: 2 / max(need, 1e-6))
    }

    /// Whether a picture kept of a piece holds a part of it as sharp as asked.
    private static func holds(_ had: Kept, _ part: FilmPictures.Part) -> Bool {
        let rect = had.part?.rect ?? had.picture.rect
        return rect.insetBy(dx: -0.01, dy: -0.01).contains(part.rect) && had.scale >= part.scale * 0.99
    }

    /// New pictures have come: placed for where the film is now. On a stage already showing,
    /// at once, or with the screen's next frame while the film plays, and the canvas is left as it
    /// is; else the canvas draws again, which shows the stage.
    private func placeNew(showing: Bool) {
        guard showing, screen > 0, let board = store.filmBoard, shownBoard == board.id, let signature, signature.version == store.version else {
            store.canvas?.redrawForArrivals()
            return
        }
        guard !store.film.playing else { return }
        let t = store.filmTime
        Self.still { place(board, at: t, pixels: screen) }
        // The playhead went on while they were drawn: what moves inside is drawn for where it is now.
        if changing, t != drawnAt, !making { prepare(board, at: t, pixels: signature.step, frame: gate.frame, again: true) }
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
                var piece = Shown(piece: item.piece, subject: item.subject, rect: had.picture.rect, reach: had.reach, layer: layer,
                                  picture: had.picture, sharp: FilmPictures.sharpness(of: had.picture), blurred: blurred.contains(item.piece.key))
                // A part laid over it before stays until `place` finds out whether it still fits.
                if let was = shown.first(where: { $0.layer === layer }) {
                    piece.over = was.over
                    piece.part = was.part
                    piece.overPicture = was.overPicture
                }
                next.append(piece)
            }
        }
        shown = next
        order = Array(next.indices)
        // What is no longer among them, a piece's layer or the part over it, leaves the stage.
        Self.still { stack() }
        shownBoard = board
        // Pictures not on the stage for a while are let go, and the parts of pieces that left it.
        kept = kept.filter { $0.value.used >= installs - 3 }
        let here = Set(next.map(\.piece.key))
        sharper = sharper.filter { here.contains($0.key) }
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

    /// The name of a layer that shows a part of a piece, sharper, over the piece's whole picture.
    static let partName = "part"
    /// The name of the layer that shows the film's frame under a camera that blurs.
    static let lensName = "lens"

    /// Puts the layers on the stage in the order the pieces are stacked, each part right over
    /// its piece.
    private func stack() {
        scene.sublayers = order.flatMap { i in [shown[i].layer] + (shown[i].over.map { [$0] } ?? []) }
    }

    // MARK: Placing

    /// Places every piece where the camera shows it at a moment, `pixels` of the screen to the
    /// artboard's point. `playing` while the film runs: then the parts to draw sharper are found
    /// for where it is about to be as well, since drawing one takes a few frames.
    private func place(_ board: Node, at t: Double, pixels: CGFloat, playing: Bool = false) {
        guard !shown.isEmpty else { return }
        let camera = board.camera(at: t)
        let pieces = shown.map(\.piece), layers = layers(on: board)
        let placements = pieces.indices.map { board.placement(of: pieces[$0], layer: layers[$0], at: t, camera: camera) }
        let wanted = board.filmOrder(pieces, placements)
        if wanted != order {
            order = wanted
            stack()
        }
        let window = window(of: board)
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
            let r = shown[i].reach
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
            fit(i, p, hidden: behind, window: window, pixels: pixels, playing: playing)
            // The part over it is placed as it is: the same map, from where the part begins.
            if let over = shown[i].over, let part = shown[i].part {
                let map = p.map.after(.translation(Double(part.rect.minX), Double(part.rect.minY)))
                var m = CATransform3DIdentity
                m.m11 = map.a; m.m21 = map.b; m.m41 = map.c
                m.m12 = map.d; m.m22 = map.e; m.m42 = map.f
                m.m14 = map.g; m.m24 = map.h; m.m44 = map.i
                over.transform = m
                over.opacity = Float(p.opacity)
            }
        }
        sharpen(board, at: t, now: placements, window: window, pixels: pixels, playing: playing)
        focus(board, placements, pixels: pixels)
    }

    // MARK: Sharp however near

    /// The layer each piece on the stage places.
    private func layers(on board: Node) -> [Node?] {
        let pieces = shown.map(\.piece)
        if let had = placing, had.version == store.version, had.fronts == store.fronts, had.board == board.id, had.pieces == pieces {
            return had.layers
        }
        let layers = board.filmLayers(of: pieces)
        placing = (store.version, store.fronts, board.id, pieces, layers)
        return layers
    }

    /// The part of the film's frame that shows in the stage, in the artboard's points: what is
    /// scrolled out of the view needs no drawing. `frame` is where the film's frame is in the
    /// view, when it is not yet where the gate lies.
    private func window(of board: Node, frame: CGRect? = nil) -> CGRect {
        let frame = frame ?? gate.frame
        let seen = frame.intersection(bounds)
        guard frame.width > 0, frame.height > 0, !seen.isNull, seen.width > 0, seen.height > 0 else { return .zero }
        let kx = board.frame.width / frame.width, ky = board.frame.height / frame.height
        return CGRect(x: (seen.minX - frame.minX) * kx, y: (seen.minY - frame.minY) * ky, width: seen.width * kx, height: seen.height * ky)
    }

    /// What shows of a piece through the window, and how many pixels to the point that takes,
    /// when its whole picture does not hold it: shown larger than the picture is sharp, or lying
    /// past what the picture covers. Nil for a piece whose picture will do, one that does not
    /// show, and one that is blurred anyway.
    private func magnified(_ i: Int, _ p: FilmPlacement, window: CGRect, pixels: CGFloat) -> (seen: CGRect, need: Double)? {
        guard p.blur <= 0.05, p.opacity > 0.001, let seen = p.map.seen(of: shown[i].reach, through: window) else { return nil }
        let need = seen.stretch * Double(pixels)
        let within = shown[i].rect.insetBy(dx: -0.01, dy: -0.01).contains(seen.part)
        guard need > Double(shown[i].sharp) * 1.05 || !within else { return nil }
        return (seen.part, need)
    }

    /// The part kept of a piece, while it is still of what the piece shows.
    private func held(_ i: Int) -> Sharper? {
        let key = shown[i].piece.key
        guard let part = sharper[key] else { return nil }
        guard part.subject.isDrawn(as: shown[i].subject) else {
            sharper[key] = nil
            return nil
        }
        return part
    }

    /// The part to draw for what shows of a piece. One rule for asking and for telling whether
    /// what is kept will do, so that a part once drawn for a view is the part that view asks for.
    private func part(_ i: Int, seen: CGRect, need: Double, playing: Bool) -> FilmPictures.Part? {
        FilmPictures.part(for: seen, of: shown[i].reach, need: CGFloat(need), margin: playing ? 0.05 : 0.1)
    }

    /// Whether a part kept covers what shows of a piece, sharp enough and not so much sharper
    /// that its fine lines would flicker made small. A film that plays may go a little soft
    /// before a part is drawn again.
    private func covers(_ kept: Sharper, _ i: Int, seen: CGRect, need: Double, playing: Bool) -> Bool {
        guard kept.part.rect.insetBy(dx: -0.01, dy: -0.01).contains(seen), Double(kept.part.scale) <= need * 2.5 else { return false }
        // No sharper than a part may be: one held back by its size is as sharp as it gets.
        let most = part(i, seen: seen, need: need, playing: playing).map { Double($0.scale) } ?? need
        return Double(kept.part.scale) >= min(need, most) * (playing ? 0.85 : 0.999)
    }

    /// Lays the part kept of a piece over its whole picture where it shows larger than that
    /// holds, and takes it off where it does not.
    private func fit(_ i: Int, _ p: FilmPlacement, hidden: Bool, window: CGRect, pixels: CGFloat, playing: Bool) {
        guard !hidden, let now = magnified(i, p, window: window, pixels: pixels) else {
            cover(i, with: nil)
            // Nothing of it shows larger than its picture: its part is let go. Not while the
            // film plays, when the part may have been drawn for where it is about to be.
            if !hidden, p.blur <= 0.05, !playing { sharper[shown[i].piece.key] = nil }
            return
        }
        if let kept = held(i), kept.part.rect.intersects(now.seen),
           kept.part.scale > shown[i].sharp * 1.05 || !shown[i].rect.contains(kept.part.rect) {
            cover(i, with: kept)
        } else {
            cover(i, with: nil)
        }
    }

    /// Shows a part over a piece's whole picture, or none. The whole picture gives way under it,
    /// or what is not solid, a shadow or a soft edge, would be laid on twice there.
    private func cover(_ i: Int, with kept: Sharper?) {
        guard let kept else {
            guard shown[i].over != nil || shown[i].part != nil else { return }
            shown[i].over?.removeFromSuperlayer()
            shown[i].over = nil
            shown[i].part = nil
            shown[i].overPicture = nil
            shown[i].layer.mask = nil
            return
        }
        let layer = shown[i].layer
        let over = shown[i].over ?? {
            let l = CALayer()
            l.name = Self.partName
            l.anchorPoint = .zero
            l.position = .zero
            l.contentsGravity = .resize
            l.magnificationFilter = .linear
            l.minificationFilter = .linear
            scene.insertSublayer(l, above: layer)
            shown[i].over = l
            return l
        }()
        let hole = layer.mask as? CAShapeLayer
        guard shown[i].part != kept.part || over.contents as AnyObject? !== kept.picture.image || hole?.bounds != layer.bounds else { return }
        over.contents = kept.picture.image
        over.bounds = kept.picture.rect
        // But for a hair along the part's edge, where both lie, so that no seam shows between them.
        let hair = 0.5 / kept.part.scale
        let mask = hole ?? CAShapeLayer()
        // In the piece's own points, which are the artboard's.
        mask.anchorPoint = .zero
        mask.position = layer.bounds.origin
        mask.bounds = layer.bounds
        mask.fillRule = .evenOdd
        let path = CGMutablePath()
        path.addRect(layer.bounds)
        path.addRect(kept.picture.rect.insetBy(dx: hair, dy: hair))
        mask.path = path
        if layer.mask !== mask { layer.mask = mask }
        shown[i].part = kept.part
        shown[i].overPicture = kept.picture
    }

    // MARK: A camera that blurs

    /// A frame for the lens: every piece's pictures and where the film has them.
    private struct LensJob: @unchecked Sendable {
        var cuts: [[FilmExport.Cut]]
        var placements: [FilmPlacement]
        var order: [Int]
        var backdrop: RGBA
        var board: CGSize
        /// The film's frame in the screen's pixels, and the part of it to make, as Core Image
        /// counts: up from the bottom left.
        var size: CGSize
        var part: CGRect
        /// That part in the artboard's points, from its top left.
        var covers: CGRect
        var round: Int
    }

    /// What tells one frame of the lens from another.
    private struct LensLook: Equatable {
        var placements: [FilmPlacement]
        var order: [Int]
        var pictures: [ObjectIdentifier]
        var backdrop: RGBA
        var size: CGSize
        var part: CGRect
    }

    /// A picture handed to the thread that fills it.
    private struct LensSurface: @unchecked Sendable {
        let surface: IOSurface
    }

    /// Shows the film through the lens where the camera blurs something that stands off its
    /// focus, and takes the lens away where it blurs nothing. The frame is the film's on the
    /// screen, pixel for pixel, and only what of it shows in the view is made, with a little
    /// round it for a view on its way.
    private func focus(_ board: Node, _ placements: [FilmPlacement], pixels: CGFloat) {
        let zoom = store.viewport.zoom, frame = gate.frame, sheet = board.frame.size
        guard zoom > 0, pixels > 0, frame.width > 0, frame.height > 0, placements.count == shown.count else { return unlens() }
        let backing = pixels / zoom
        let size = CGSize(width: max(1, (frame.width * backing).rounded()), height: max(1, (frame.height * backing).rounded()))
        guard placements.contains(where: { p in p.opacity >= 0.001 && p.soft.map { FilmExport.blurs($0, board: sheet, size: size) } == true }) else {
            return unlens()
        }
        let seen = frame.intersection(bounds)
        guard !seen.isNull, seen.width > 0, seen.height > 0 else { return }
        // In steps, so that a view that scrolls asks for pictures of another size only now and then.
        let step: CGFloat = 64
        let x0 = max(0, ((seen.minX - frame.minX) * backing / step).rounded(.down) * step - step)
        let y0 = max(0, ((seen.minY - frame.minY) * backing / step).rounded(.down) * step - step)
        let x1 = min(size.width, ((seen.maxX - frame.minX) * backing / step).rounded(.up) * step + step)
        let y1 = min(size.height, ((seen.maxY - frame.minY) * backing / step).rounded(.up) * step + step)
        guard x1 > x0, y1 > y0 else { return }
        var cuts: [[FilmExport.Cut]] = [], pictures: [ObjectIdentifier] = []
        for piece in shown {
            let whole = still(piece.picture)
            pictures.append(ObjectIdentifier(piece.picture.image))
            if piece.over != nil, let over = piece.overPicture {
                // Its part over it, and the whole picture giving way there, as the layers have it.
                let part = still(over)
                pictures.append(ObjectIdentifier(over.image))
                cuts.append([FilmExport.Cut(still: whole, under: part), FilmExport.Cut(still: part)])
            } else {
                cuts.append([FilmExport.Cut(still: whole)])
            }
        }
        let part = CGRect(x: x0, y: size.height - y1, width: x1 - x0, height: y1 - y0)
        let backdrop = Self.onScreen(board.filmBackdrop, in: space)
        let look = LensLook(placements: placements, order: order, pictures: pictures, backdrop: backdrop, size: size, part: part)
        // Asked for already: shown, or on its way.
        guard look != lensAsked else { return }
        lensAsked = look
        if stills.count > pictures.count * 2 + 8 {
            let used = Set(pictures)
            stills = stills.filter { used.contains($0.key) }
        }
        let kx = sheet.width / size.width, ky = sheet.height / size.height
        let job = LensJob(cuts: cuts, placements: placements, order: order, backdrop: backdrop, board: sheet, size: size, part: part,
                          covers: CGRect(x: x0 * kx, y: y0 * ky, width: (x1 - x0) * kx, height: (y1 - y0) * ky), round: lensRound)
        // One at a time: the newest asked for while one is made is made next, and those between are not.
        if lensing { lensNext = job } else { make(job) }
    }

    /// A piece's picture as Core Image takes it. The stage's pictures are in the screen's own
    /// colours and shown in them, so their numbers are taken as they are.
    private func still(_ picture: FilmPictures.Picture) -> FilmExport.Still {
        let id = ObjectIdentifier(picture.image)
        if let had = stills[id] { return had.still }
        let still = FilmExport.Still.asItIs(picture)
        stills[id] = (picture.image, still)
        return still
    }

    /// A colour in the numbers the screen's colours have for it.
    private static func onScreen(_ color: RGBA, in space: CGColorSpace?) -> RGBA {
        guard let space, let made = color.cgColor.converted(to: space, intent: .defaultIntent, options: nil),
              let v = made.components, v.count >= 3 else { return color }
        return RGBA(r: Double(v[0]), g: Double(v[1]), b: Double(v[2]), a: color.a)
    }

    /// A picture to make the lens's next frame in: one of three by turns, so neither the one the
    /// screen shows nor the one it showed before. Said to be in the screen's colours, as the
    /// pieces' pictures are, so that nothing converts it again.
    private func surface(_ width: Int, _ height: Int) -> IOSurface? {
        guard width > 0, height > 0, width * height <= 80_000_000 else { return nil }
        if let first = surfaces.first, first.width != width || first.height != height { surfaces = [] }
        guard surfaces.count < 3 else {
            turn = (turn + 1) % surfaces.count
            return surfaces[turn]
        }
        guard let made = IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA]) else { return nil }
        if let space = space ?? CGColorSpace(name: CGColorSpace.sRGB) {
            if let list = space.copyPropertyList() {
                made.setAttachment(list, forKey: kIOSurfaceColorSpace as String)
            } else if let profile = space.copyICCData() {
                made.setAttachment(profile, forKey: kIOSurfaceICCProfile as String)
            }
        }
        surfaces.append(made)
        turn = surfaces.count - 1
        return made
    }

    /// Makes a frame for the lens, away from here, and shows it when it has come.
    private func make(_ job: LensJob) {
        guard let surface = surface(Int(job.part.width), Int(job.part.height)) else {
            lensing = false
            return
        }
        lensing = true
        let target = LensSurface(surface: surface)
        Self.lensQueue.async {
            let began = CACurrentMediaTime()
            let image = FilmExport.composed({ job.cuts[$0] }, placements: job.placements, order: job.order, backdrop: job.backdrop, board: job.board, size: job.size)
            let destination = CIRenderDestination(ioSurface: target.surface)
            // In the pictures' own numbers, which are the screen's.
            destination.colorSpace = nil
            let made = (try? FilmExport.imaging.startTask(toRender: image, from: job.part, to: destination, at: .zero).waitUntilCompleted()) != nil
            let took = CACurrentMediaTime() - began
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.show(target.surface, of: job, made: made, took: took) }
            }
        }
    }

    /// A frame of the lens has come: shown, unless the lens was put away meanwhile. Then the
    /// newest asked for since is made.
    private func show(_ surface: IOSurface, of job: LensJob, made: Bool, took: Double) {
        #if DEBUG
        lensFrames += 1
        lensSpent += took
        lensLongest = max(lensLongest, took)
        #endif
        if made, job.round == lensRound {
            Self.still {
                lens.contents = surface
                lensShown = (surface, job.covers, job.board)
                fitLens()
                if lens.isHidden {
                    lens.isHidden = false
                    scene.isHidden = true
                }
            }
        }
        if let next = lensNext {
            lensNext = nil
            make(next)
        } else {
            lensing = false
        }
    }

    /// Lays the lens's picture over the part of the artboard it covers, in the gate as it lies now.
    private func fitLens() {
        guard let shown = lensShown, shown.board.width > 0, shown.board.height > 0 else { return }
        let kx = gate.bounds.width / shown.board.width, ky = gate.bounds.height / shown.board.height
        lens.bounds = CGRect(x: 0, y: 0, width: shown.covers.width * kx, height: shown.covers.height * ky)
        lens.position = CGPoint(x: shown.covers.minX * kx, y: shown.covers.minY * ky)
    }

    /// Takes the lens away: the pieces' own layers show the film again, placed as they are.
    private func unlens() {
        guard lensAsked != nil || lensNext != nil || lensShown != nil || scene.isHidden else { return }
        lensRound += 1
        lensAsked = nil
        lensNext = nil
        lensShown = nil
        Self.still {
            scene.isHidden = false
            lens.isHidden = true
            lens.contents = nil
        }
    }

    /// The moment a film that plays shows a while after another.
    private func moment(_ t: Double, after seconds: Double, on board: Node) -> Double {
        let length = board.filmLength, to = t + seconds
        guard to > length else { return to }
        if board.film?.once == true || store.film.pass?.to != nil { return length }
        // Round again, after its breath at the end.
        return min(max(to - length - FilmDesk.breath, 0), length)
    }

    /// Has the parts drawn that show larger than their pieces' pictures hold and are not covered
    /// by what is kept: all of them in one go, away from here, and nothing more is asked for
    /// until they have come. A film that plays asks for where it will be in the next third of a
    /// second, every few frames.
    private func sharpen(_ board: Node, at t: Double, now: [FilmPlacement], window: CGRect, pixels: CGFloat, playing: Bool) {
        guard !sharpening, window.width > 0 else { return }
        var moments = [now]
        if playing {
            sinceAhead += 1
            guard sinceAhead >= 4 else { return }
            sinceAhead = 0
            let pieces = shown.map(\.piece), layers = layers(on: board)
            for seconds in [0.15, 0.3] {
                let then = moment(t, after: seconds, on: board), camera = board.camera(at: then)
                moments.append(pieces.indices.map { board.placement(of: pieces[$0], layer: layers[$0], at: then, camera: camera) })
            }
        }
        var jobs: [PartJob] = []
        for i in shown.indices {
            var all = CGRect.null, most = 0.0, short = false
            for placements in moments {
                let p = placements[i], r = shown[i].reach
                let behind = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
                    .allSatisfy { p.map.depth(at: $0) <= 1e-3 }
                guard !behind, let m = magnified(i, p, window: window, pixels: pixels) else { continue }
                all = all.union(m.seen)
                most = max(most, m.need)
                if let kept = held(i), covers(kept, i, seen: m.seen, need: m.need, playing: playing) { continue }
                short = true
            }
            guard short, let part = part(i, seen: all, need: most, playing: playing) else { continue }
            // A part held back by its size to no sharper than the whole picture is not worth drawing.
            guard part.scale > shown[i].sharp * 1.05 || !shown[i].rect.insetBy(dx: -0.01, dy: -0.01).contains(all) else { continue }
            jobs.append(PartJob(key: shown[i].piece.key, subject: shown[i].subject, part: part))
        }
        guard !jobs.isEmpty else { return }
        sharpening = true
        let assets = store.assets, round = sharpRound, space = Space(space: space)
        let work = jobs
        Self.queue.async {
            let jobs = work
            let made = FilmMade()
            DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
                made.put(jobs[i].key, FilmPictures.picture(of: jobs[i].subject, scale: jobs[i].part.scale, assets: assets, part: jobs[i].part, space: space.space))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.sharpening = false
                    #if DEBUG
                    self.partsMade += jobs.count
                    #endif
                    // Asked for before the stage was put away: of another film, or none.
                    guard round == self.sharpRound else { return }
                    for job in jobs {
                        guard let picture = made.all[job.key] else { continue }
                        self.sharper[job.key] = Sharper(subject: job.subject, part: job.part, picture: picture)
                    }
                    // Laid over their pieces at once, or with the film's next frame.
                    self.placeNew(showing: !self.gate.isHidden)
                }
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
        layFromTheTop()
        screen = store.viewport.zoom * (window?.backingScaleFactor ?? 2)
        Self.still { place(board, at: t, pixels: screen, playing: true) }
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

    /// How many pictures have been drawn since the stage was made, and how many parts of
    /// pieces, sharper than their pictures.
    private(set) var picturesMade = 0
    private(set) var partsMade = 0
    /// Whether pictures are being drawn right now, away from here.
    var isDrawing: Bool { making || sharpening || lensing }
    /// How sharp the pieces' pictures were last asked to be, in pixels to the point at the view's zoom.
    var sharpnessAsked: CGFloat? { signature?.step }
    /// How many frames the lens has made, and how long they took, in all and the longest, in seconds.
    private(set) var lensFrames = 0
    private(set) var lensSpent = 0.0
    private(set) var lensLongest = 0.0
    /// What the lens shows, while the film shows through it: its picture, eight bits to a
    /// colour in the stage's colours, and the part of the artboard it covers, in the artboard's
    /// points from its top left.
    var lensPicture: (image: CGImage, covers: CGRect)? {
        guard !lens.isHidden, let shown = lensShown else { return nil }
        let surface = shown.surface
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let data = Data(bytes: surface.baseAddress, count: surface.bytesPerRow * surface.height)
        guard let provider = CGDataProvider(data: data as CFData), let space = space ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let image = CGImage(width: surface.width, height: surface.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: surface.bytesPerRow,
                                  space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return (image, shown.covers)
    }
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
    private var reached: [String: CGRect] = [:]

    func put(_ key: String, _ picture: FilmPictures.Picture?, reach: CGRect = .null) {
        guard let picture else { return }
        lock.lock()
        pictures[key] = picture
        if !reach.isNull { reached[key] = reach }
        lock.unlock()
    }

    var all: [String: FilmPictures.Picture] {
        lock.lock()
        defer { lock.unlock() }
        return pictures
    }

    /// Where each picture's subject draws at all, with what the picture covers.
    var reaches: [String: CGRect] {
        lock.lock()
        defer { lock.unlock() }
        return reached
    }
}
