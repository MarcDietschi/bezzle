import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// The prototype played over the design, as the Mac's PlayerOverlay (Views/Player.swift): over the
/// panels and the canvas, under the bar, the stage turns to graph paper, and the screen lifts off
/// the canvas and settles into the device it is for, lit from above. Under it, what was said of
/// the way just taken, in the designer's hand; and the few controls there are. The device's
/// screen shows pictures the core makes once (`WindowsCore.Player.Shot`), which are only moved
/// about, frame by frame, as the Mac's PlayerScreenView moves its layers: nothing is drawn while
/// they move.
@MainActor
final class PlayerView {
    let layer = Grid()
    let player: WindowsCore.Player
    /// Where a part of the canvas lies, in the layer's points; nil when it is out of sight.
    var canvasRect: (CGRect) -> CGRect? = { _ in nil }
    /// Before flying back: the screen brought into view on the canvas, and picked.
    var landing: (UUID) -> Void = { _ in }
    /// Gone, once the screen has landed.
    var closed: () -> Void = {}

    private let paper = Border()
    private let stage = Image()
    private let room = Canvas()
    private let shadow = Image()
    private let device = Grid()
    private let deviceMove = CompositeTransform()
    private var figure: FrameworkElement?
    private let screenDark = Border()
    private let screenBox = Border()
    private let content = Canvas()
    private let island = Border()
    private let flyer = Border()
    private let flyerImage = Image()
    private let under = StackPanel()
    private let caption = TextBlock()
    private let captionClip = RectangleGeometry()
    private let name = TextBlock()
    private let controls = StackPanel()
    private var buttons: [(box: Border, glyph: [Glyphs.Part], enabled: () -> Bool)] = []

    private var form: Devices.Form
    private var pixelScale = 1.0
    /// The screen as laid out: its size in the layer's points, and where it lies in the layer.
    private var screenSize = CGSize.zero
    private var screenRect = CGRect.zero
    private var radius = 0.0
    private var deviceSize = CGSize.zero
    private var deviceOrigin = CGPoint.zero
    /// The layer's size it was laid out for.
    private var laidOut = CGSize.zero
    private var started = false

    /// Arriving (settling in) or leaving (flying back), and since when.
    private var leaving = false
    private var phaseStart = 0.0
    /// Where the flying picture comes from and goes back to; nil fades instead.
    private var flyFrom: CGRect?
    private var shakeStart: Double?
    private var refusalsSeen = 0
    private var captionsSeen = 0

    /// Device points to the layer's points, and to pixels.
    private var k: Double { Double(screenSize.width) / max(Double(player.screen.width), 1) }
    private var pixels: Double { k * pixelScale }

    // The pictures on the screen: kept by name and size, the screen at rest, a move under way.
    private var cache: [String: WriteableBitmap] = [:]
    private var cacheOrder: [String] = []
    private var rest: (shot: WindowsCore.Player.Shot, holder: Canvas, elements: [FrameworkElement])?
    private var motion: (shot: WindowsCore.Player.Shot, holder: Canvas, elements: [FrameworkElement])?
    private var aheadQueue: [WindowsCore.Player.Sprite] = []

    // Everything that moves, frame by frame, while it does.
    private var animations: [(Double) -> Bool] = []
    private var ticking: EventCleanup?

    init(player: WindowsCore.Player) {
        self.player = player
        form = Devices.form(group: player.device.group, name: player.device.name, width: Double(player.screen.width), height: Double(player.screen.height))

        // The paper, and in it the same well the canvas lies in, ruled and lit; a press on it stops playing.
        paper.background = Theme.brush(Theme.paper)
        let well = Border()
        well.cornerRadius = Theme.corners(12)
        well.margin = Theme.inset(9, 0, 9, 9)
        well.borderBrush = Theme.brush(Theme.shadow, 0.16)
        well.borderThickness = Theme.inset(0.5, 1.5, 0.5, 0.5)
        well.background = Theme.brush(Theme.table)
        stage.stretch = .fill
        stage.isHitTestVisible = false
        well.child = stage
        paper.child = well
        paper.opacity = 0
        paper.pointerPressed.addHandler { [weak self] _, args in
            args?.handled = true
            self?.player.close()
        }
        layer.children.append(paper)

        room.isHitTestVisible = true
        shadow.isHitTestVisible = false
        shadow.stretch = .fill
        room.children.append(shadow)
        device.renderTransform = deviceMove
        device.opacity = 0
        room.children.append(device)
        flyer.isHitTestVisible = false
        flyerImage.stretch = .fill
        flyer.child = flyerImage
        room.children.append(flyer)

        caption.fontFamily = FontFamily("Segoe Print")
        caption.fontSize = 19
        caption.foreground = Theme.brush(Theme.dark ? 0xB9C9FA : 0x2F4FB5)
        caption.textAlignment = .center
        caption.horizontalAlignment = .center
        caption.verticalAlignment = .center
        caption.textWrapping = .wrap
        caption.maxLines = 2
        caption.clip = captionClip
        let captionRow = Grid()
        captionRow.height = 30
        captionRow.children.append(caption)
        name.fontFamily = Theme.ui
        name.fontSize = 11.5
        name.fontWeight = FontWeight(weight: 500)
        name.foreground = Theme.ink(3)
        name.horizontalAlignment = .center
        under.spacing = 8
        under.isHitTestVisible = false
        under.children.append(captionRow)
        under.children.append(name)
        under.opacity = 0
        room.children.append(under)
        layer.children.append(room)

        // Back, from the start again, and done: round, quiet.
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.horizontalAlignment = .right
        controls.verticalAlignment = .top
        controls.margin = Theme.inset(0, 18, 22, 0)
        controls.opacity = 0
        addButton(Glyphs.back(size: 32), help: "Back  ←", enabled: { [weak player] in player?.canGoBack == true }) { [weak self] in self?.player.back() }
        addButton(Glyphs.restart(size: 32), help: "From the Start  R", enabled: { [weak player] in player?.canGoBack == true }) { [weak self] in self?.player.restart() }
        addButton(Glyphs.cross(size: 32), help: "Stop Playing  esc", enabled: { true }) { [weak self] in self?.player.close() }
        layer.children.append(controls)

        screenDark.background = Theme.brush(0x000000)
        screenDark.isHitTestVisible = false
        screenBox.background = Theme.brush(0xFFFFFF)
        screenBox.child = content
        screenBox.opacity = 0
        island.background = Theme.brush(0x000000)
        island.isHitTestVisible = false
        content.isHitTestVisible = false
        screenBox.pointerMoved.addHandler { [weak self] _, args in self?.pointed(args) }
        screenBox.pointerExited.addHandler { [weak self] _, _ in
            guard let self else { return }
            _ = self.player.hover(at: nil)
            self.screenBox.protectedCursor = Pointer.arrow.cursor
        }
        screenBox.pointerPressed.addHandler { [weak self] _, args in
            guard let self, let at = self.point(args) else { return }
            args?.handled = true
            _ = try? self.screenBox.capturePointer(args?.pointer)
            self.takeKeys()
            self.player.down(at: at)
        }
        screenBox.pointerReleased.addHandler { [weak self] _, args in
            guard let self, let at = self.point(args) else { return }
            args?.handled = true
            try? self.screenBox.releasePointerCaptures()
            self.player.up(at: at)
            self.pointed(args)
        }
        screenBox.pointerWheelChanged.addHandler { [weak self] _, args in
            guard let self, let properties = (try? args?.getCurrentPoint(self.screenBox))?.properties else { return }
            args?.handled = true
            self.player.scroll(by: BezzleCore.CGFloat(Double(properties.mouseWheelDelta) / 3))
        }
        // Presses on the device itself, round its screen, don't stop playing.
        device.pointerPressed.addHandler { _, args in args?.handled = true }

        player.changed = { [weak self] in self?.changed() }
        player.moving = { [weak self] in self?.beginMotion() }
        player.flash = { [weak self] rects in self?.flash(rects) }
        player.scrolled = { [weak self] in self?.placeRest() }
        player.closing = { [weak self] board in self?.leave(board) }

        layer.sizeChanged.addHandler { [weak self] _, _ in self?.layout() }
        // The keys come here while it plays, and from here to the window's own handler.
        layer.isTabStop = true
        layer.useSystemFocusVisuals = false
        layer.background = Theme.clear
        layer.pointerPressed.addHandler { [weak self] _, _ in self?.takeKeys() }
    }

    /// The keys, here.
    func takeKeys() { _ = try? layer.focus(.programmatic) }

    // MARK: Laying out

    private func layout() {
        let w = layer.actualWidth, h = layer.actualHeight
        guard w > 0, h > 0, CGSize(width: w, height: h) != laidOut else { return }
        laidOut = CGSize(width: w, height: h)
        pixelScale = layer.xamlRoot?.rasterizationScale ?? 1
        let raw = Devices.metrics(form, player.screen)
        let fit = min((w - 120) / max(Double(raw.size.width), 1), (h - 200) / max(Double(raw.size.height), 1), 1.25)
        let size = CGSize(width: Double(player.screen.width) * fit, height: Double(player.screen.height) * fit)
        let resized = size != screenSize
        screenSize = size
        let (view, m) = Devices.view(form, screen: size)
        deviceSize = m.size
        radius = m.radius
        deviceOrigin = CGPoint(x: (w - Double(m.size.width)) / 2, y: max(28, (h - Double(m.size.height)) / 2 - 34))
        screenRect = m.screen.offsetBy(dx: deviceOrigin.x, dy: deviceOrigin.y)

        // The device, its screen dark until the picture lands in it, the pictures, the island over them.
        device.children.clear()
        figure = view
        device.children.append(view)
        device.width = Double(m.size.width)
        device.height = Double(m.size.height)
        for e in [screenDark, screenBox] {
            e.width = Double(m.screen.width)
            e.height = Double(m.screen.height)
            e.horizontalAlignment = .left
            e.verticalAlignment = .top
            e.margin = Theme.inset(Double(m.screen.minX), Double(m.screen.minY), 0, 0)
            e.cornerRadius = Theme.corners(m.radius)
            device.children.append(e)
        }
        content.width = Double(m.screen.width)
        content.height = Double(m.screen.height)
        if case .phone(true) = form {
            let sw = Double(m.screen.width)
            island.width = sw * 0.3
            island.height = max(1.5, sw * 0.085)
            island.cornerRadius = Theme.corners(island.height / 2)
            island.horizontalAlignment = .left
            island.verticalAlignment = .top
            island.margin = Theme.inset(Double(m.screen.midX) - sw * 0.15, Double(m.screen.minY) + max(1.2, sw * 0.035), 0, 0)
            device.children.append(island)
        }
        try? Canvas.setLeft(device, Double(deviceOrigin.x))
        try? Canvas.setTop(device, Double(deviceOrigin.y))
        deviceMove.centerX = Double(m.size.width) / 2
        deviceMove.centerY = Double(m.size.height) / 2

        // Standing on the sheet, lit from above: a soft shadow round it.
        let inset = min(Double(m.size.width), Double(m.size.height)) * 0.08
        let sw = Int(((Double(m.size.width) - inset * 2) * pixelScale).rounded()), sh = Int(((Double(m.size.height) - inset * 2) * pixelScale).rounded())
        let pad = Int((70 * pixelScale).rounded())
        var bitmap: WriteableBitmap?
        _ = WindowsCore.softShadow(width: sw, height: sh, pad: pad, blur: 34 * pixelScale, dy: 0, colour: Theme.shadow, alpha: 0.22) { bw, bh in
            bitmap = WriteableBitmap(Int32(bw), Int32(bh))
            return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        try? bitmap?.invalidate()
        shadow.source = bitmap
        shadow.width = Double(sw + 2 * pad) / pixelScale
        shadow.height = Double(sh + 2 * pad) / pixelScale
        try? Canvas.setLeft(shadow, Double(deviceOrigin.x) + inset - Double(pad) / pixelScale)
        try? Canvas.setTop(shadow, Double(deviceOrigin.y) + inset - Double(pad) / pixelScale + 24)

        let underWidth = max(Double(m.size.width), 420)
        under.width = underWidth
        try? Canvas.setLeft(under, (w - underWidth) / 2)
        try? Canvas.setTop(under, Double(deviceOrigin.y) + Double(m.size.height) + 22)

        lightStage(w, h)
        if resized {
            cache.removeAll()
            cacheOrder.removeAll()
            rest?.holder.removeFromParent(content)
            rest = nil
            showRest(fading: false)
        }
        if !started {
            started = true
            arrive()
        } else {
            placeFlyer(settle: leaving ? 0 : 1)
        }
    }

    private func lightStage(_ w: Double, _ h: Double) {
        let pw = Int(((w - 18) * pixelScale).rounded()), ph = Int(((h - 9) * pixelScale).rounded())
        guard pw > 0, ph > 0 else { return }
        var bitmap: WriteableBitmap?
        _ = WindowsCore.playerStage(width: pw, height: ph, scale: pixelScale, table: Theme.table, dark: Theme.dark) { bw, bh in
            bitmap = WriteableBitmap(Int32(bw), Int32(bh))
            return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        try? bitmap?.invalidate()
        stage.source = bitmap
    }

    // MARK: Arriving and leaving

    /// A spring from 0 to 1 over time, as SwiftUI's with this response and damping.
    private static func spring(_ t: Double, response: Double, damping z: Double) -> Double {
        guard t > 0 else { return 0 }
        let w = 2 * Double.pi / response
        guard z < 1 else { return 1 - (1 + w * t) * exp(-w * t) }
        let wd = w * (1 - z * z).squareRoot()
        return 1 - exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t))
    }

    /// The screen off the canvas into the device.
    private func arrive() {
        flyFrom = player.canvasFrame(of: player.visit.board).flatMap(canvasRect)
        showSnapshot()
        phaseStart = WindowsCore.now
        name.text = player.name
        animate { [weak self] now in
            guard let self, !self.leaving else { return false }
            let t = now - self.phaseStart
            self.settle(Self.spring(t, response: 0.52, damping: 0.82), lit: min(1, t / 0.35))
            return t < 1.2
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.player.phase == .arriving else { return }
                self.player.phase = .playing
                self.live(true)
            }
        }
    }

    /// The end of playing: the screen, brought into view on the canvas, flies back to it.
    private func leave(_ board: UUID) {
        landing(board)
        leaving = true
        live(false)
        showSnapshot()
        flyFrom = player.canvasFrame(of: board).flatMap(canvasRect)
        phaseStart = WindowsCore.now
        animate { [weak self] now in
            guard let self else { return false }
            let t = now - self.phaseStart
            self.settle(1 - Self.spring(t, response: 0.44, damping: 0.9), lit: 1 - min(1, t / 0.3))
            return t < 0.5
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    private func finish() {
        ticking?.dispose()
        ticking = nil
        animations.removeAll()
        player.stop()
        closed()
    }

    /// Everything as far settled as `s` (0 on the canvas, 1 in the device), the stage as lit.
    private func settle(_ s: Double, lit: Double) {
        let o = min(max(s, 0), 1)
        paper.opacity = min(max(lit, 0), 1)
        device.opacity = o
        shadow.opacity = o
        deviceMove.scaleX = 0.94 + 0.06 * s
        deviceMove.scaleY = 0.94 + 0.06 * s
        under.opacity = o
        controls.opacity = o
        placeFlyer(settle: s)
    }

    /// The picture flying between the canvas and the device's screen, `s` of the way in.
    private func placeFlyer(settle s: Double) {
        let to = screenRect
        let from = flyFrom ?? to.insetBy(dx: to.width * 0.1, dy: to.height * 0.1)
        func mix(_ a: BezzleCore.CGFloat, _ b: BezzleCore.CGFloat) -> Double { Double(a) + (Double(b) - Double(a)) * s }
        try? Canvas.setLeft(flyer, mix(from.minX, to.minX))
        try? Canvas.setTop(flyer, mix(from.minY, to.minY))
        flyer.width = max(1, mix(from.width, to.width))
        flyer.height = max(1, mix(from.height, to.height))
        flyer.cornerRadius = Theme.corners(2 + (radius - 2) * min(max(s, 0), 1))
        flyer.opacity = flyFrom == nil ? min(max(s, 0), 1) : 1
    }

    /// The screen in front as one picture, for flying.
    private func showSnapshot() {
        let scale = max(k, 0.25) * pixelScale
        var bitmap: WriteableBitmap?
        _ = player.snapshot(scale: scale) { w, h in
            bitmap = WriteableBitmap(Int32(w), Int32(h))
            return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        try? bitmap?.invalidate()
        flyerImage.source = bitmap
    }

    /// The screen live in the device, or the flying picture in its place.
    private func live(_ on: Bool) {
        screenBox.opacity = on ? 1 : 0
        flyer.visibility = on ? .collapsed : .visible
        if on { changed() }
    }

    // MARK: Keys

    /// A key while playing: Escape stops, Left or Backspace goes back, R starts again. Every
    /// other key is kept from the design under it.
    func key(_ args: KeyRoutedEventArgs) {
        args.handled = true
        switch args.key {
        case .escape: _ = player.key("escape")
        case .left: _ = player.key("left")
        case .back: _ = player.key("back")
        case .r: _ = player.key("r")
        default: break
        }
    }

    // MARK: What shows

    /// What shows changed: the controls, the caption, the screen's name, a shake for no way back,
    /// and the screen at rest, a copy's new look coming in over its old one.
    private func changed() {
        for b in buttons {
            let on = b.enabled()
            b.box.child = Glyphs.view(b.glyph, size: 32, brush: Theme.ink(on ? 2 : 4))
        }
        name.text = player.name
        if player.captions != captionsSeen {
            captionsSeen = player.captions
            write(player.caption)
        }
        if player.refusals != refusalsSeen {
            refusalsSeen = player.refusals
            shake()
        }
        guard player.phase == .playing else { return }
        showRest(fading: true)
    }

    /// What was said of the way just taken, written out by hand from its start.
    private func write(_ text: String?) {
        caption.text = text ?? ""
        guard let text, !text.isEmpty else { captionClip.rect = Rect(x: 0, y: 0, width: 0, height: 0); return }
        let start = WindowsCore.now + 0.2, length = min(0.4 + Double(text.count) * 0.025, 1.2)
        captionClip.rect = Rect(x: 0, y: 0, width: 0, height: 0)
        animate { [weak self] now in
            guard let self, self.caption.text == text else { return false }
            let u = min(max((now - start) / length, 0), 1)
            let eased = 1 - (1 - u) * (1 - u)
            let w = self.caption.actualWidth * eased + 30
            self.captionClip.rect = Rect(x: -20, y: -10, width: Float(w + 20), height: Float(self.caption.actualHeight + 20))
            return u < 1
        }
    }

    /// No way back: the device shakes its head.
    private func shake() {
        let start = WindowsCore.now
        animate { [weak self] now in
            guard let self else { return false }
            let t = now - start
            self.deviceMove.translateX = t < 0.6 ? 9 * exp(-7 * t) * sin(2 * Double.pi * t / 0.16) : 0
            return t < 0.6
        }
    }

    private func pointed(_ args: PointerRoutedEventArgs?) {
        guard let at = point(args) else { return }
        let tappable = player.hover(at: at)
        screenBox.protectedCursor = (tappable ? Pointer.pointingHand : Pointer.arrow).cursor
    }

    /// Where the pointer is on the device's screen, in the design's points.
    private func point(_ args: PointerRoutedEventArgs?) -> CGPoint? {
        guard k > 0, let p = try? args?.getCurrentPoint(screenBox)?.position else { return nil }
        return CGPoint(x: Double(p.x) / k, y: Double(p.y) / k)
    }

    private func addButton(_ glyph: [Glyphs.Part], help: String, enabled: @escaping () -> Bool, _ action: @escaping @MainActor () -> Void) {
        let box = Border()
        box.width = 32
        box.height = 32
        box.cornerRadius = Theme.corners(16)
        box.background = Theme.brush(Theme.card)
        box.borderBrush = Theme.hairline
        box.borderThickness = Theme.inset(0.5)
        box.child = Glyphs.view(glyph, size: 32, brush: Theme.ink(2))
        box.pointerEntered.addHandler { _, _ in if enabled() { box.child = Glyphs.view(glyph, size: 32, brush: Theme.ink(1)) } }
        box.pointerExited.addHandler { _, _ in box.child = Glyphs.view(glyph, size: 32, brush: Theme.ink(enabled() ? 2 : 4)) }
        box.pointerPressed.addHandler { _, args in args?.handled = true }
        box.tapped.addHandler { [weak self] _, args in
            args?.handled = true
            self?.takeKeys()
            if enabled() { action() }
        }
        try? ToolTipService.setToolTip(box, Words.t(help).replacingOccurrences(of: "  esc", with: "  Esc"))
        controls.children.append(box)
        buttons.append((box, glyph, enabled))
    }

    // MARK: The screen's pictures

    private func bitmap(_ sprite: WindowsCore.Player.Sprite) -> WriteableBitmap? {
        let key = "\(sprite.key)@\(pixels)"
        if let b = cache[key] { return b }
        var bitmap: WriteableBitmap?
        guard sprite.make(scale: pixels, into: { w, h in
            bitmap = WriteableBitmap(Int32(w), Int32(h))
            return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }), let made = bitmap else { return nil }
        try? made.invalidate()
        cache[key] = made
        cacheOrder.append(key)
        while cacheOrder.count > 48 { cache[cacheOrder.removeFirst()] = nil }
        return made
    }

    /// A shot's pictures as elements, in its order, on a canvas of their own.
    private func build(_ shot: WindowsCore.Player.Shot) -> (Canvas, [FrameworkElement]) {
        let holder = Canvas()
        holder.isHitTestVisible = false
        var elements: [FrameworkElement] = []
        for sprite in shot.sprites {
            let e: FrameworkElement
            switch sprite.look {
            case .dark:
                let dark = Border()
                dark.background = Theme.brush(0x000000)
                e = dark
            case .picture:
                let image = Image()
                image.stretch = .fill
                image.source = bitmap(sprite)
                if sprite.corners > 0 {
                    let r = sprite.corners * k
                    let round = Border()
                    round.cornerRadius = CornerRadius(topLeft: r, topRight: r, bottomRight: 0, bottomLeft: 0)
                    round.child = image
                    e = round
                } else {
                    e = image
                }
            }
            holder.children.append(e)
            elements.append(e)
        }
        return (holder, elements)
    }

    private func place(_ elements: [FrameworkElement], _ spots: [WindowsCore.Player.Spot]) {
        for (e, s) in zip(elements, spots) {
            try? Canvas.setLeft(e, Double(s.rect.minX) * k)
            try? Canvas.setTop(e, Double(s.rect.minY) * k)
            e.width = max(0.5, Double(s.rect.width) * k)
            e.height = max(0.5, Double(s.rect.height) * k)
            e.opacity = s.opacity
        }
    }

    /// The screen in front as it looks now; at once when its picture is made already.
    private func showRest(fading: Bool) {
        guard motion == nil, k > 0, let shot = player.rest() else { return }
        if rest?.shot.key == shot.key { placeRest(); return }
        let (holder, elements) = build(shot)
        content.children.append(holder)
        let old = rest
        rest = (shot, holder, elements)
        placeRest()
        if let old {
            if fading {
                // A copy's new look comes in over its old one, quickly.
                holder.opacity = 0
                let start = WindowsCore.now
                animate { [weak self] now in
                    let u = min((now - start) / 0.14, 1)
                    holder.opacity = u
                    if u >= 1 { old.holder.removeFromParent(self?.content) }
                    return u < 1
                }
            } else {
                old.holder.removeFromParent(content)
            }
        }
        makeAhead()
    }

    /// The screen in front where it is scrolled to.
    private func placeRest() {
        guard let rest else { return }
        place(rest.elements, rest.shot.place(0))
    }

    /// The screens the one in front leads to, made ahead one at a time, so a tap moves at once.
    private func makeAhead() {
        aheadQueue = player.ahead()
        nextAhead()
    }

    private func nextAhead() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.motion == nil, !self.aheadQueue.isEmpty else { return }
                _ = self.bitmap(self.aheadQueue.removeFirst())
                self.nextAhead()
            }
        }
    }

    /// A move from one screen to the next: its pictures (most made already), then it plays.
    private func beginMotion() {
        if let m = motion {
            m.holder.removeFromParent(content)
            motion = nil
        }
        aheadQueue.removeAll()
        guard k > 0, let shot = player.motion() else {
            player.doneMoving()
            showRest(fading: false)
            return
        }
        let made = WindowsCore.now
        let (holder, elements) = build(shot)
        Trace.say("player: \(shot.key) pictures \(Int((WindowsCore.now - made) * 1000)) ms, \(shot.sprites.count) sprites")
        content.children.append(holder)
        motion = (shot, holder, elements)
        player.startMoving()
        let (p, _) = player.transit?.progress(WindowsCore.now) ?? (1, true)
        place(elements, shot.place(p))
        if let rest {
            rest.holder.removeFromParent(content)
            self.rest = nil
        }
        animate { [weak self] now in
            guard let self, let m = self.motion, m.holder === holder else { return false }
            guard let t = self.player.transit else {
                self.endMotion()
                return false
            }
            let (p, done) = t.progress(now)
            self.place(elements, shot.place(p))
            if done { self.endMotion() }
            return !done
        }
    }

    /// The move's last frame stays until the screen's own picture is there to take its place.
    private func endMotion() {
        player.doneMoving()
        let last = motion
        motion = nil
        showRest(fading: false)
        last?.holder.removeFromParent(content)
    }

    /// Everything on the screen in front that can be tapped, lit for a moment.
    private func flash(_ rects: [CGRect]) {
        guard !rects.isEmpty, k > 0 else { return }
        let marks = Canvas()
        marks.isHitTestVisible = false
        for r in rects {
            let box = Border()
            let rr = r.insetBy(dx: -3, dy: -3)
            box.width = Double(rr.width) * k
            box.height = Double(rr.height) * k
            box.cornerRadius = Theme.corners(6)
            box.background = Theme.brush(0x3A63D8, 0.2)
            box.borderBrush = Theme.brush(0x3A63D8, 0.9)
            box.borderThickness = Theme.inset(1.5)
            try? Canvas.setLeft(box, Double(rr.minX) * k)
            try? Canvas.setTop(box, Double(rr.minY) * k)
            marks.children.append(box)
        }
        content.children.append(marks)
        let start = WindowsCore.now
        animate { [weak self] now in
            let u = min((now - start) / 0.9, 1)
            marks.opacity = 1 - u * u
            if u >= 1 { marks.removeFromParent(self?.content) }
            return u < 1
        }
    }

    // MARK: Frames

    private func animate(_ step: @escaping (Double) -> Bool) {
        animations.append(step)
        guard ticking == nil else { return }
        ticking = CompositionTarget.rendering.addHandler { [weak self] _, _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let now = WindowsCore.now
        animations = animations.filter { $0(now) }
        if animations.isEmpty {
            ticking?.dispose()
            ticking = nil
        }
    }
}

private extension UIElement {
    /// Taken off the canvas it lies on.
    func removeFromParent(_ canvas: Canvas?) {
        guard let canvas else { return }
        var index: UInt32 = 0
        if (try? canvas.children.indexOf(self, &index)) == true { canvas.children.removeAt(index) }
    }
}
