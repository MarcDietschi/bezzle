import AppKit
import QuartzCore

// MARK: - What a screen shows

/// A visit to a screen as it shows at one moment: the screen with its copies' states, and for a
/// sheet the screen under it. Its key tells one look of it from another.
nonisolated struct PlayerScene: Sendable {
    let key: String
    let board: Node
    let under: Node?
    let screen: CGSize

    var sheetRect: CGRect {
        CGRect(x: (screen.width - board.frame.width) / 2, y: screen.height - board.frame.height, width: board.frame.width, height: board.frame.height)
    }
}

/// Pictures of the prototype's screens, made once (away from the main thread) and then only moved
/// about by Core Animation, so the motion between screens is the graphics card's alone.
nonisolated enum PlayerPictures {
    /// How much smaller a screen wider than the device is drawn, to fit across it.
    static func fit(_ board: Node, in screen: CGSize) -> CGFloat {
        board.frame.width > screen.width + 0.5 ? screen.width / board.frame.width : 1
    }

    /// A screen whole, all its height, `scale` pixels to its point, fitted across the device: with
    /// only some of its layers, or all but some, or without its own ground.
    static func board(_ b: Node, screen: CGSize, scale: CGFloat, assets: Assets?, skipping: Set<UUID> = [], only: Set<UUID>? = nil,
                      background: Bool = true) -> CGImage? {
        var b = b
        b.frame.origin = .zero
        if let only { b.children = b.children.filter { only.contains($0.id) } }
        if !skipping.isEmpty { b.children.removeAll { skipping.contains($0.id) } }
        let f = fit(b, in: screen)
        let size = CGSize(width: max(1, (b.frame.width * f * scale).rounded()), height: max(1, (b.frame.height * f * scale).rounded()))
        guard let ctx = Renderer.bitmap(size) else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: scale * f, y: -scale * f)
        Renderer.withFlippedContext(ctx) {
            var o = Renderer.Options()
            o.deviceScale = scale * f
            o.assets = assets
            Renderer.drawArtboard(b, in: ctx, options: o, background: background)
        }
        return ctx.makeImage()
    }

    /// One layer alone, lying in what holds it at `origin` on its screen, with all it paints round
    /// it, its shadow too: the picture, and where on the screen it lies.
    static func layer(_ n: Node, origin: CGPoint, board: Node, scale: CGFloat, assets: Assets?) -> (CGImage, CGRect)? {
        let r = rect(of: n, origin: origin, board: board)
        guard r.width > 0, r.height > 0, r.width * scale < 6000, r.height * scale < 6000 else { return nil }
        let size = CGSize(width: max(1, (r.width * scale).rounded()), height: max(1, (r.height * scale).rounded()))
        guard let ctx = Renderer.bitmap(size) else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -r.minX, y: -r.minY)
        Renderer.withFlippedContext(ctx) {
            var o = Renderer.Options()
            o.deviceScale = scale
            o.assets = assets
            o.board = board
            o.offset = origin
            ctx.translateBy(x: origin.x, y: origin.y)
            Renderer.drawNode(n, in: ctx, options: o)
        }
        return ctx.makeImage().map { ($0, r) }
    }

    /// Where one layer alone paints on its screen, with all round it, seen from the screen's eye
    /// as it is drawn (`Eye.stage`): what its picture covers, and where a move lays it.
    static func rect(of n: Node, origin: CGPoint, board: Node) -> CGRect {
        Renderer.reach(of: n, eye: Eye.stage(board.frame.size).inside(origin)).offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1, dy: -1).integral
    }

    /// The device's screen as one picture: a screen scrolled, or a sheet over the screen under it.
    static func composite(_ s: PlayerScene, scroll: CGFloat, scale: CGFloat, assets: Assets?) -> CGImage? {
        let size = CGSize(width: (s.screen.width * scale).rounded(), height: (s.screen.height * scale).rounded())
        guard let ctx = Renderer.bitmap(size) else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: scale, y: -scale)
        Renderer.withFlippedContext(ctx) {
            var o = Renderer.Options()
            o.deviceScale = scale
            o.assets = assets
            ctx.setFillColor(CGColor.white)
            ctx.fill(CGRect(origin: .zero, size: s.screen))
            func draw(_ b: Node, at p: CGPoint) {
                ctx.saveGState()
                ctx.translateBy(x: p.x, y: p.y)
                let f = fit(b, in: s.screen)
                ctx.scaleBy(x: f, y: f)
                var b = b
                b.frame.origin = .zero
                Renderer.drawArtboard(b, in: ctx, options: o)
                ctx.restoreGState()
            }
            if let under = s.under {
                draw(under, at: .zero)
                ctx.setFillColor(CGColor(gray: 0, alpha: 0.34))
                ctx.fill(CGRect(origin: .zero, size: s.screen))
                let r = s.sheetRect
                let path = sheetPath(r)
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 24, color: CGColor(gray: 0, alpha: 0.3))
                ctx.addPath(path)
                ctx.setFillColor(s.board.fill.on ? s.board.fill.color.cgColor : CGColor.white)
                ctx.fillPath()
                ctx.restoreGState()
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()
                draw(s.board, at: r.origin)
                ctx.restoreGState()
            } else {
                draw(s.board, at: CGPoint(x: 0, y: -scroll))
            }
        }
        return ctx.makeImage()
    }

    /// A sheet's outline: its top corners round, running on past the foot of the screen.
    static func sheetPath(_ r: CGRect) -> CGPath {
        let radius = sheetRadius(r)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r.minX, y: r.maxY + 40))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        path.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        path.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + radius), control: CGPoint(x: r.maxX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY + 40))
        path.closeSubpath()
        return path
    }

    static func sheetRadius(_ r: CGRect) -> CGFloat { min(16, r.width * 0.04) }

    /// Whether a group can be taken apart into its layers for a morph and look the same: nothing
    /// done to it as a whole.
    static func apart(_ g: Node) -> Bool {
        g.isGroup && g.mask == nil && g.clipsToFirst != true && g.opacity >= 0.999 && g.blur == nil && g.blend == nil
            && g.transform3D == nil && !g.shadow.on && g.moreShadows?.contains(where: \.on) != true
    }
}

/// Pictures made on other threads, handed back together.
private nonisolated final class Made: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: CGImage] = [:]

    func put(_ key: String, _ image: CGImage?) {
        guard let image else { return }
        lock.lock()
        images[key] = image
        lock.unlock()
    }

    var all: [String: CGImage] {
        lock.lock()
        defer { lock.unlock() }
        return images
    }
}

/// A picture to make, and what it is called.
private struct Job: Sendable {
    let key: String
    let make: @Sendable () -> CGImage?
}

// MARK: - The device's screen

/// The device's screen. At rest it shows the screen in front as a picture, moved as it scrolls and
/// changed for another when a copy changes its look; between screens, pictures of both, or of
/// their layers for a morph, are moved about by Core Animation, frame by frame, as a spring
/// carries them, and nothing is drawn while they move.
final class PlayerScreenView: NSView {
    let player: Player
    /// Everything shown, in the device's points, y down.
    private let content = CALayer()
    private var rest: Rest?
    /// The look of the screen being made, by its key: only that one is shown when it comes.
    private var making: String?
    private var motion: Motion?
    /// A move just ended, its last frame showing until the screen's own picture takes its place.
    private var leaving: CALayer?
    /// Counts the moves begun, so a move's pictures that come after another began are dropped.
    private var generation = 0
    private var link: CADisplayLink?
    private var tracking: NSTrackingArea?
    private var cache: [String: CGImage] = [:]
    private var cacheOrder: [String] = []
    private static let queue = DispatchQueue(label: "Bezzle prototype pictures", qos: .userInteractive)

    /// The screen at rest: its picture's layer, and where it lies at no scroll.
    private struct Rest {
        let key: String
        let root: CALayer
        let picture: CALayer
        let frame: CGRect
        let scrolls: Bool
    }

    /// A move under way: its layers, and what puts them where they are part of the way.
    private struct Motion {
        let root: CALayer
        let apply: (CGFloat) -> Void
    }

    init(player: Player) {
        self.player = player
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        content.masksToBounds = true
        content.backgroundColor = CGColor.white
        player.view = self
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {}

    override func layout() {
        super.layout()
        guard let layer else { return }
        if content.superlayer == nil { layer.addSublayer(content) }
        // Sublayers laid out from the top, as the view is.
        content.isGeometryFlipped = !layer.isGeometryFlipped
        let was = content.frame.size
        Self.still { content.frame = bounds }
        if was != bounds.size, bounds.width > 0 {
            // A new size: the pictures again, sharp at it.
            cache.removeAll()
            cacheOrder.removeAll()
            refresh(force: true)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        cache.removeAll()
        cacheOrder.removeAll()
        refresh(force: true)
    }

    /// Device points to view points.
    private var k: CGFloat { bounds.width / max(player.screen.width, 1) }
    /// Device points to the screen's pixels.
    private var pixels: CGFloat { k * (window?.backingScaleFactor ?? 2) }

    private static func still(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: Pictures

    private func remember(_ key: String, _ image: CGImage) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = image
        while cacheOrder.count > 48 { cache[cacheOrder.removeFirst()] = nil }
    }

    /// Makes the pictures not made yet, away from here, then hands them all over here.
    private func make(_ jobs: [Job], then done: @escaping @MainActor @Sendable ([String: CGImage]) -> Void) {
        var have: [String: CGImage] = [:]
        var missing: [Job] = []
        for j in jobs {
            if let image = cache[j.key] { have[j.key] = image } else { missing.append(j) }
        }
        guard !missing.isEmpty else { done(have); return }
        let made = Made()
        for (key, image) in have { made.put(key, image) }
        Self.queue.async {
            DispatchQueue.concurrentPerform(iterations: missing.count) { i in made.put(missing[i].key, missing[i].make()) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(made.all) }
            }
        }
    }

    private func boardKey(_ s: PlayerScene) -> String { "\(s.key)#board@\(pixels)" }
    private func sheetKey(_ s: PlayerScene) -> String { "\(s.key)#sheet@\(pixels)" }

    private func boardJob(_ s: PlayerScene, skipping: Set<UUID> = [], only: Set<UUID>? = nil, background: Bool = true, tag: String = "") -> Job {
        let scale = pixels, assets = player.store.assets
        let key = tag.isEmpty ? boardKey(s) : "\(s.key)#\(tag)@\(scale)"
        return Job(key: key) { PlayerPictures.board(s.board, screen: s.screen, scale: scale, assets: assets, skipping: skipping, only: only, background: background) }
    }

    private func sheetJob(_ s: PlayerScene) -> Job {
        let scale = pixels, assets = player.store.assets
        return Job(key: sheetKey(s)) { PlayerPictures.composite(s, scroll: 0, scale: scale, assets: assets) }
    }

    /// A visit's picture as it rests: a screen whole, to scroll; a sheet over its screen, at the
    /// device's size.
    private func restJob(_ s: PlayerScene) -> Job { s.under == nil ? boardJob(s) : sheetJob(s) }

    private func restFrame(_ s: PlayerScene) -> CGRect {
        guard s.under == nil else { return CGRect(origin: .zero, size: s.screen) }
        let f = PlayerPictures.fit(s.board, in: s.screen)
        return CGRect(x: 0, y: 0, width: s.board.frame.width * f, height: s.board.frame.height * f)
    }

    private func pictureLayer(_ image: CGImage, _ r: CGRect) -> CALayer {
        let l = CALayer()
        l.contents = image
        l.contentsGravity = .resize
        l.frame = r.scaled(k)
        return l
    }

    // MARK: At rest

    /// Shows the screen in front as it looks now, once its picture is made; at once when it is.
    func refresh(force: Bool = false) {
        guard motion == nil, bounds.width > 0 else { return }
        var scene: PlayerScene?
        withObservationTracking {
            scene = player.scene(of: player.visit)
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        guard let scene else { return }
        let key = "\(scene.key)@\(pixels)"
        if !force, rest?.key == key { scrolled(); return }
        guard making != key || force else { return }
        making = key
        let job = restJob(scene)
        make([job]) { [weak self] images in
            guard let self, self.making == key, self.motion == nil, let image = images[job.key] else { return }
            self.remember(job.key, image)
            self.install(scene, image, key: key, fading: self.rest != nil)
            self.making = nil
            self.makeAhead()
        }
    }

    private func install(_ scene: PlayerScene, _ image: CGImage, key: String, fading: Bool) {
        let frame = restFrame(scene)
        let root = CALayer()
        let picture = pictureLayer(image, frame)
        Self.still {
            root.frame = content.bounds
            root.addSublayer(picture)
            content.addSublayer(root)
        }
        let old = rest
        rest = Rest(key: key, root: root, picture: picture, frame: frame, scrolls: scene.under == nil)
        scrolled()
        guard let old else { return }
        if fading {
            // A copy's new look comes in over its old one, quickly.
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.14)
            CATransaction.setCompletionBlock { old.root.removeFromSuperlayer() }
            root.opacity = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.14
            root.add(fade, forKey: "in")
            CATransaction.commit()
        } else {
            old.root.removeFromSuperlayer()
        }
    }

    /// The screen in front where it is scrolled to.
    func scrolled() {
        guard let rest, rest.scrolls else { return }
        Self.still { rest.picture.frame = rest.frame.offsetBy(dx: 0, dy: -player.scroll).scaled(k) }
    }

    /// The screens the one in front leads to, made ahead, so a tap moves at once.
    private func makeAhead() {
        let jobs = player.nextScenes().map { boardJob($0) }.filter { cache[$0.key] == nil }
        guard !jobs.isEmpty else { return }
        make(jobs) { [weak self] images in
            for (key, image) in images { self?.remember(key, image) }
        }
    }

    // MARK: Between screens

    /// A move from one screen to the next: its pictures are made (most of them already are), then
    /// it plays.
    func begin(_ t: Transit, a: PlayerScene?, b: PlayerScene?) {
        generation += 1
        let g = generation
        making = nil
        guard let a, let b, bounds.width > 0 else {
            player.transit = nil
            refresh(force: true)
            return
        }
        // A move cut short ends where it was going.
        if let m = motion {
            m.root.removeFromSuperlayer()
            motion = nil
        }
        leaving?.removeFromSuperlayer()
        leaving = nil
        var jobs: [Job] = []
        let build: @MainActor @Sendable ([String: CGImage]) -> Motion?
        switch t.way {
        case .push(let from, true) where a.under == nil && b.under == nil:
            let pieces = morphPieces(a.board, b.board)
            let scale = pixels, assets = player.store.assets
            for (i, p) in pieces.enumerated() {
                if let n = p.from { jobs.append(Job(key: "m\(g).\(i).a") { PlayerPictures.layer(n, origin: p.fromOrigin, board: a.board, scale: scale, assets: assets)?.0 }) }
                if let n = p.to { jobs.append(Job(key: "m\(g).\(i).b") { PlayerPictures.layer(n, origin: p.toOrigin, board: b.board, scale: scale, assets: assets)?.0 }) }
            }
            jobs.append(boardJob(a, only: [], tag: "ground"))
            jobs.append(boardJob(b, only: [], tag: "ground"))
            build = { [unowned self] images in self.morph(t, a, b, pieces, from: from, images, g) }
        case .push(let from, _):
            // What both screens have where it is, as it is, stays put over them.
            var shared: (a: Set<UUID>, b: Set<UUID>) = ([], [])
            if a.under == nil, b.under == nil, t.aScroll == 0, t.bScroll == 0 {
                let byID = Dictionary(b.board.children.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
                for (id, m) in Prototype.matches(a.board.children, b.board.children) where byID[id].map({ Prototype.same(m, $0) }) == true {
                    shared.a.insert(m.id)
                    shared.b.insert(id)
                }
            }
            if shared.a.isEmpty {
                jobs = [restJob(a), restJob(b)]
            } else {
                let tag = "less\(shared.b.count)"
                jobs = [boardJob(a, skipping: shared.a, tag: tag), boardJob(b, skipping: shared.b, tag: tag),
                        boardJob(b, only: shared.b, background: false, tag: "shared")]
            }
            build = { [unowned self] images in self.slide(t, a, b, from: from, shared: !shared.a.isEmpty, images, jobs) }
        case .sheet:
            let under = PlayerScene(key: a.key, board: a.board, under: a.under, screen: a.screen)
            jobs = [restJob(under), boardJob(b)]
            build = { [unowned self] images in self.sheet(t, a, b, images, jobs) }
        default:
            jobs = [restJob(a), restJob(b)]
            build = { [unowned self] images in self.dissolve(t, a, b, images, jobs) }
        }
        make(jobs) { [weak self] images in
            guard let self, self.generation == g, self.player.transit != nil else { return }
            for j in jobs where !j.key.hasPrefix("m") { if let image = images[j.key] { self.remember(j.key, image) } }
            guard let m = build(images) else {
                self.player.transit = nil
                self.refresh(force: true)
                return
            }
            Self.still { self.content.addSublayer(m.root) }
            self.motion = m
            self.player.transit?.start = CACurrentMediaTime()
            // The first frame at once, where the screen in front already is.
            let (p, _) = self.player.transit?.progress(CACurrentMediaTime()) ?? (1, true)
            Self.still { m.apply(p) }
            if let rest = self.rest {
                rest.root.removeFromSuperlayer()
                self.rest = nil
            }
            self.keepMoving()
        }
    }

    private func keepMoving() {
        guard link == nil else { return }
        let l = displayLink(target: self, selector: #selector(stepFrame))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func stepFrame(_ l: CADisplayLink) {
        guard let m = motion, let t = player.transit else {
            l.invalidate()
            link = nil
            return
        }
        let (p, done) = t.progress(CACurrentMediaTime())
        Self.still { m.apply(p) }
        guard done else { return }
        l.invalidate()
        link = nil
        player.transit = nil
        // The last frame stays until the screen's own picture is there to take its place.
        leaving?.removeFromSuperlayer()
        leaving = m.root
        motion = nil
        let scene = player.scene(of: player.visit)
        guard let scene else { leaving?.removeFromSuperlayer(); leaving = nil; return }
        let key = "\(scene.key)@\(pixels)"
        making = key
        let job = restJob(scene)
        let finished = generation
        make([job]) { [weak self] images in
            guard let self else { return }
            if self.generation == finished {
                self.leaving?.removeFromSuperlayer()
                self.leaving = nil
            }
            guard self.making == key, let image = images[job.key] else { return }
            self.remember(job.key, image)
            self.install(scene, image, key: key, fading: false)
            self.making = nil
            self.makeAhead()
        }
    }

    private func screenRect() -> CGRect { CGRect(origin: .zero, size: player.screen) }

    /// Where a visit's picture lies at rest, scrolled.
    private func placed(_ s: PlayerScene, scroll: CGFloat) -> CGRect {
        restFrame(s).offsetBy(dx: 0, dy: s.under == nil ? -scroll : 0)
    }

    /// The next screen slides in from its side over the one before, which gives way a little and
    /// dims under its shadow; what both have alike stays put over them.
    private func slide(_ t: Transit, _ a: PlayerScene, _ b: PlayerScene, from: CGVector, shared: Bool, _ images: [String: CGImage], _ jobs: [Job]) -> Motion? {
        guard let ai = images[jobs[0].key], let bi = images[jobs[1].key] else { return nil }
        let size = player.screen
        let root = CALayer()
        root.frame = content.bounds
        let aGroup = CALayer(), bGroup = CALayer()
        for g in [aGroup, bGroup] { g.frame = screenRect().scaled(k) }
        let aFrame = shared ? restFrame(a) : placed(a, scroll: t.aScroll)
        let bFrame = shared ? restFrame(b) : placed(b, scroll: t.bScroll)
        aGroup.addSublayer(pictureLayer(ai, aFrame))
        let dim = CALayer()
        dim.backgroundColor = CGColor(gray: 0, alpha: 1)
        dim.frame = aGroup.bounds
        dim.opacity = 0
        aGroup.addSublayer(dim)
        let bPicture = pictureLayer(bi, bFrame)
        bGroup.addSublayer(bPicture)
        bGroup.shadowColor = CGColor(gray: 0, alpha: 1)
        bGroup.shadowRadius = 14
        bGroup.shadowOffset = .zero
        bGroup.shadowPath = CGPath(rect: bGroup.bounds, transform: nil)
        root.addSublayer(aGroup)
        root.addSublayer(bGroup)
        if shared, jobs.count > 2, let si = images[jobs[2].key] {
            root.addSublayer(pictureLayer(si, restFrame(b)))
        }
        let span = CGPoint(x: from.dx * size.width * k, y: from.dy * size.height * k)
        let home = aGroup.position
        return Motion(root: root) { p in
            aGroup.position = CGPoint(x: home.x - span.x * 0.28 * p, y: home.y - span.y * 0.28 * p)
            dim.opacity = Float(0.2 * p)
            bGroup.position = CGPoint(x: home.x + span.x * (1 - p), y: home.y + span.y * (1 - p))
            bGroup.shadowOpacity = Float(0.32 * min(1, (1 - p) * 4))
        }
    }

    /// The sheet rises over the screen it opens on, which dims under it.
    private func sheet(_ t: Transit, _ a: PlayerScene, _ b: PlayerScene, _ images: [String: CGImage], _ jobs: [Job]) -> Motion? {
        guard let ui = images[jobs[0].key], let si = images[jobs[1].key] else { return nil }
        let root = CALayer()
        root.frame = content.bounds
        root.addSublayer(pictureLayer(ui, placed(a, scroll: t.aScroll)))
        let dim = CALayer()
        dim.backgroundColor = CGColor(gray: 0, alpha: 1)
        dim.frame = root.bounds
        dim.opacity = 0
        root.addSublayer(dim)
        let r = b.sheetRect
        let holder = CALayer()
        holder.frame = r.scaled(k)
        holder.shadowColor = CGColor(gray: 0, alpha: 1)
        holder.shadowOpacity = 0.3
        holder.shadowRadius = 14
        holder.shadowOffset = CGSize(width: 0, height: -2)
        let radius = PlayerPictures.sheetRadius(r) * k
        holder.shadowPath = CGPath(roundedRect: holder.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let picture = pictureLayer(si, CGRect(origin: .zero, size: r.size))
        picture.cornerRadius = radius
        picture.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        picture.masksToBounds = true
        holder.addSublayer(picture)
        root.addSublayer(holder)
        let rest = holder.position
        let drop = (r.height + 24) * k
        return Motion(root: root) { p in
            dim.opacity = Float(0.34 * p)
            holder.position = CGPoint(x: rest.x, y: rest.y + drop * (1 - p))
        }
    }

    /// The next screen fades in over the one before.
    private func dissolve(_ t: Transit, _ a: PlayerScene, _ b: PlayerScene, _ images: [String: CGImage], _ jobs: [Job]) -> Motion? {
        guard let ai = images[jobs[0].key], let bi = images[jobs[1].key] else { return nil }
        let root = CALayer()
        root.frame = content.bounds
        root.addSublayer(pictureLayer(ai, placed(a, scroll: t.aScroll)))
        let b = pictureLayer(bi, placed(b, scroll: t.bScroll))
        b.opacity = 0
        root.addSublayer(b)
        return Motion(root: root) { p in b.opacity = Float(p) }
    }

    // MARK: Morphing

    /// A layer of the first screen and the same layer on the second, or one that is only on one of
    /// them, each lying in what holds it at an origin on its screen.
    private struct Piece {
        var from: Node?
        var fromOrigin: CGPoint = .zero
        var to: Node?
        var toOrigin: CGPoint = .zero
    }

    /// The two screens' layers paired by name, groups that are alike taken apart into theirs.
    private func morphPieces(_ a: Node, _ b: Node) -> [Piece] {
        var out: [Piece] = []
        func pair(_ x: [Node], _ xo: CGPoint, _ y: [Node], _ yo: CGPoint) {
            let pairs = Prototype.matches(x, y)
            let used = Set(pairs.values.map(\.id))
            for m in x where !m.hidden && !used.contains(m.id) { out.append(Piece(from: m, fromOrigin: xo)) }
            for n in y where !n.hidden {
                guard let m = pairs[n.id] else { out.append(Piece(to: n, toOrigin: yo)); continue }
                if PlayerPictures.apart(m), PlayerPictures.apart(n) {
                    pair(m.children, CGPoint(x: xo.x + m.frame.minX, y: xo.y + m.frame.minY), n.children, CGPoint(x: yo.x + n.frame.minX, y: yo.y + n.frame.minY))
                } else {
                    out.append(Piece(from: m, fromOrigin: xo, to: n, toOrigin: yo))
                }
            }
        }
        pair(a.children, .zero, b.children, .zero)
        return out
    }

    /// What the two screens share moves to its new place and takes its new look; what is only on
    /// the first fades as it drifts away, and what is only on the second fades in, drifting into
    /// place from the side it comes from; the ground between them changes colour.
    private func morph(_ t: Transit, _ a: PlayerScene, _ b: PlayerScene, _ pieces: [Piece], from: CGVector, _ images: [String: CGImage], _ g: Int) -> Motion? {
        let root = CALayer()
        root.frame = content.bounds
        let world = CALayer()
        world.frame = root.bounds
        root.addSublayer(world)
        let groundA = images["\(a.key)#ground@\(pixels)"].map { pictureLayer($0, restFrame(a)) }
        let groundB = images["\(b.key)#ground@\(pixels)"].map { pictureLayer($0, restFrame(b)) }
        if let groundA { world.addSublayer(groundA) }
        if let groundB { groundB.opacity = 0; world.addSublayer(groundB) }
        let drift: CGFloat = 22
        struct Moving { let holder: CALayer; let a: CALayer?; let b: CALayer?; let ra: CGRect?; let rb: CGRect? }
        var moving: [Moving] = []
        for (i, p) in pieces.enumerated() {
            let ia = images["m\(g).\(i).a"], ib = images["m\(g).\(i).b"]
            // Laid where its picture was drawn over, seen from each screen's eye.
            let ra = p.from.map { PlayerPictures.rect(of: $0, origin: p.fromOrigin, board: a.board) }
            let rb = p.to.map { PlayerPictures.rect(of: $0, origin: p.toOrigin, board: b.board) }
            let holder = CALayer()
            var la: CALayer?, lb: CALayer?
            if let ia { let l = CALayer(); l.contents = ia; l.contentsGravity = .resize; holder.addSublayer(l); la = l }
            if let ib { let l = CALayer(); l.contents = ib; l.contentsGravity = .resize; holder.addSublayer(l); lb = l }
            guard la != nil || lb != nil else { continue }
            world.addSublayer(holder)
            moving.append(Moving(holder: holder, a: la, b: lb, ra: ia != nil ? ra : nil, rb: ib != nil ? rb : nil))
        }
        let k = self.k
        func smooth(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
            let u = min(max((x - e0) / (e1 - e0), 0), 1)
            return u * u * (3 - 2 * u)
        }
        func mix(_ r: CGRect, _ s: CGRect, _ p: CGFloat) -> CGRect {
            CGRect(x: r.minX + (s.minX - r.minX) * p, y: r.minY + (s.minY - r.minY) * p,
                   width: r.width + (s.width - r.width) * p, height: r.height + (s.height - r.height) * p)
        }
        return Motion(root: root) { p in
            world.frame = root.bounds.offsetBy(dx: 0, dy: -(t.aScroll * (1 - p) + t.bScroll * p) * k)
            groundB?.opacity = Float(p)
            for m in moving {
                var r: CGRect
                if let ra = m.ra, let rb = m.rb {
                    r = mix(ra, rb, p)
                    m.a?.opacity = Float(1 - smooth(0.35, 1, p))
                    m.b?.opacity = Float(smooth(0, 0.65, p))
                } else if let ra = m.ra {
                    r = ra.offsetBy(dx: -from.dx * drift * p, dy: -from.dy * drift * p)
                    m.holder.opacity = Float(1 - p)
                } else if let rb = m.rb {
                    r = rb.offsetBy(dx: from.dx * drift * (1 - p), dy: from.dy * drift * (1 - p))
                    m.holder.opacity = Float(p)
                } else {
                    continue
                }
                m.holder.frame = r.scaled(k)
                m.a?.frame = m.holder.bounds
                m.b?.frame = m.holder.bounds
            }
        }
    }

    // MARK: What can be tapped

    /// Everything on the screen in front that can be tapped, lit for a moment.
    func flash(_ rects: [CGRect]) {
        guard !rects.isEmpty else { return }
        let marks = CALayer()
        Self.still {
            marks.frame = content.bounds
            for r in rects {
                let l = CALayer()
                l.frame = r.insetBy(dx: -3, dy: -3).scaled(k)
                l.cornerRadius = 6
                l.backgroundColor = Theme.hex(0x3A63D8, 0.2).cgColor
                l.borderColor = Theme.hex(0x3A63D8, 0.9).cgColor
                l.borderWidth = 1.5
                marks.addSublayer(l)
            }
            content.addSublayer(marks)
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { marks.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.9
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        marks.add(fade, forKey: "fade")
        marks.opacity = 0
        CATransaction.commit()
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private func point(_ event: NSEvent) -> CGPoint {
        let v = convert(event.locationInWindow, from: nil)
        return CGPoint(x: v.x / k, y: v.y / k)
    }

    override func mouseMoved(with event: NSEvent) {
        let tappable = player.hover(at: point(event))
        (tappable ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        _ = player.hover(at: nil)
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) { player.down(at: point(event)) }
    override func mouseUp(with event: NSEvent) {
        player.up(at: point(event))
        let tappable = player.hover(at: point(event))
        (tappable ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func scrollWheel(with event: NSEvent) {
        player.scrolled(by: event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            link?.invalidate()
            link = nil
        }
    }
}

private extension CGRect {
    func scaled(_ k: CGFloat) -> CGRect { CGRect(x: minX * k, y: minY * k, width: width * k, height: height * k) }
}
