import AppKit
import QuartzCore

/// What the canvas draws of the others in a live room, each in their own coloured pencil, with
/// the marks Bezzle already draws in blue for you: where they look, as a soft light on the table;
/// their hand, shaped like the tool they hold; what they hold, outlined; what they drag, moving
/// as they drag it; what they changed, lit up for a moment; and a ripple where they shook their
/// pointer. Everything glides there, as a hand would, rather than stepping as the network does.
final class LiveMarks {
    private struct Hand {
        var at: CGPoint
        var target: CGPoint
        var alpha: CGFloat = 0
        var tag: CGFloat = 0
        var tagUntil: CFTimeInterval = 0
        var lastMoved: CFTimeInterval = 0
    }

    private var hands: [UInt32: Hand] = [:]
    /// Each person's gaze as drawn, in canvas points.
    private var lights: [UInt32: CGRect] = [:]
    private var lightAlpha: [UInt32: CGFloat] = [:]
    /// Layers others are dragging, as drawn this frame.
    private var drawn: [UUID: Node] = [:]
    private var crop: CGFloat = 0
    private var cropPerson: LiveRoom.Person?
    private var arrivals: [UInt32: CFTimeInterval] = [:]
    private var last: CFTimeInterval = 0
    private var dt: CFTimeInterval = 1.0 / 60
    private var stepped: CFTimeInterval = -1
    private var easing = false
    /// The design as last drawn, with what others drag.
    private var shown: BezzleDocument?

    /// Whether something others drag is still on its way: the artboards it is on are drawn as
    /// they change, as when dragging here.
    private(set) var isMoving = false
    /// Whether anything is still easing, so the canvas keeps drawing.
    var isAnimating: Bool { easing || isMoving }

    func arrived(_ peer: UInt32) { arrivals[peer] = CACurrentMediaTime() }

    /// How long a picture takes to come into focus once it is here.
    static let focusing: CFTimeInterval = 1.1
    /// How long a picture on its way clears quickly at first, drawn every frame; after that it
    /// only breathes and its grain moves, a dozen times a second, until it comes.
    private static let clearing: CFTimeInterval = 2.5
    /// Where pictures on their way were drawn in sight last frame, on the canvas: only that is
    /// drawn again as their grain moves.
    private(set) var developingArea: CGRect?

    // MARK: Moving

    private func step(_ room: LiveRoom, _ store: DocumentStore, _ now: CFTimeInterval) {
        guard now != stepped else { return }
        stepped = now
        dt = last == 0 ? 1.0 / 60 : min(max(now - last, 0.001), 0.1)
        last = now
        room.forget(before: now)
        var moving = false
        let k = { (tau: Double) -> CGFloat in CGFloat(1 - exp(-self.dt / tau)) }
        let zoom = store.viewport.zoom
        let mine = room.pointer.map(store.viewport.toView)

        for peer in Set(hands.keys).union(room.presence.keys) {
            let p = room.presence[peer]
            if var hand = hands[peer] {
                if let target = p?.pointer {
                    if target != hand.target {
                        if now - hand.lastMoved > 1.5 { hand.tagUntil = max(hand.tagUntil, now + 2) }
                        hand.lastMoved = now
                        hand.target = target
                    }
                }
                let d = CGPoint(x: hand.target.x - hand.at.x, y: hand.target.y - hand.at.y)
                if hypot(d.x, d.y) * zoom > 0.25 {
                    let s = k(0.075)
                    hand.at = CGPoint(x: hand.at.x + d.x * s, y: hand.at.y + d.y * s)
                    moving = true
                } else {
                    hand.at = hand.target
                }
                let wantAlpha: CGFloat = p?.pointer == nil ? 0 : (p?.away == true ? 0.38 : 1)
                hand.alpha = ease(hand.alpha, wantAlpha, k(0.12), &moving)
                let near = mine.map { m in hypot(store.viewport.toView(hand.at).x - m.x, store.viewport.toView(hand.at).y - m.y) < 80 } ?? false
                let typing = p?.doing == .typing || p?.doing == .moving
                let wantTag: CGFloat = p?.away == false && (now < hand.tagUntil || near || typing) ? 1 : 0
                hand.tag = ease(hand.tag, wantTag, k(wantTag > hand.tag ? 0.07 : 0.22), &moving)
                if now < hand.tagUntil { moving = true }
                if p == nil && hand.alpha < 0.01 { hands[peer] = nil } else { hands[peer] = hand }
            } else if let target = p?.pointer {
                let until = arrivals[peer].map { $0 + 3 } ?? now + 2
                hands[peer] = Hand(at: target, target: target, tagUntil: until, lastMoved: now)
                moving = true
            }
        }

        for peer in Set(lights.keys).union(room.presence.keys) {
            let want: CGFloat = room.presence[peer] == nil ? 0 : (room.presence[peer]?.away == true ? 0.5 : 1)
            var a = lightAlpha[peer] ?? 0
            a = ease(a, want, k(0.3), &moving)
            if let target = room.presence[peer]?.view {
                if let r = lights[peer] {
                    let s = k(0.14)
                    let next = Self.mix(r, target, s)
                    let off: CGFloat = max(abs(next.minX - target.minX), abs(next.minY - target.minY), abs(next.width - target.width))
                    if off * zoom > 0.3 {
                        moving = true
                        lights[peer] = next
                    } else {
                        lights[peer] = target
                    }
                } else {
                    lights[peer] = target
                }
            }
            if want == 0 && a < 0.01 { lights[peer] = nil; lightAlpha[peer] = nil } else { lightAlpha[peer] = a }
        }

        room.developed(before: now)
        for d in room.developing.values where now - d.since < Self.clearing || d.arrived != nil { moving = true }

        if let peer = room.following, let person = room.person(peer) { cropPerson = person }
        crop = ease(crop, room.following == nil ? 0 : 1, k(room.following == nil ? 0.08 : 0.12), &moving)
        easing = moving || !room.winks.isEmpty || !room.glows.isEmpty
    }

    private static func mix(_ a: CGRect, _ b: CGRect, _ s: CGFloat) -> CGRect {
        let x: CGFloat = a.minX + (b.minX - a.minX) * s
        let y: CGFloat = a.minY + (b.minY - a.minY) * s
        let w: CGFloat = a.width + (b.width - a.width) * s
        let h: CGFloat = a.height + (b.height - a.height) * s
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func ease(_ value: CGFloat, _ target: CGFloat, _ k: CGFloat, _ moving: inout Bool) -> CGFloat {
        if abs(target - value) < 0.004 { return target }
        moving = true
        return value + (target - value) * k
    }

    /// The design with what others are dragging, eased toward where they have it now.
    func overlaid(_ doc: BezzleDocument, room: LiveRoom, store: DocumentStore) -> BezzleDocument {
        _ = room.beat
        let now = CACurrentMediaTime()
        step(room, store, now)
        room.settle(store.doc, at: now)
        guard !room.motion.isEmpty || !drawn.isEmpty else {
            isMoving = false
            shown = nil
            return doc
        }
        var targets: [UUID: Node] = [:]
        for m in room.motion.values { for (id, n) in m.nodes { targets[id] = n } }
        let k = 1 - exp(-dt / 0.055)
        let zoom = store.viewport.zoom
        var next: [UUID: Node] = [:]
        var moving = false
        var out = doc
        func put(_ id: UUID, _ n: Node) {
            next[id] = n
            out.update(id) { node in
                let kids = node.children
                node = n
                node.children = kids
            }
        }
        for (id, target) in targets {
            guard let base = doc.node(id) else { continue }
            let from = drawn[id] ?? Self.alone(base)
            if Self.close(from, target, zoom) {
                put(id, target)
            } else {
                put(id, from.blended(to: target, k))
                moving = true
            }
        }
        // A drag that went without its change, as when its maker left: back to the design as it is.
        for (id, was) in drawn where targets[id] == nil {
            guard let base = doc.node(id) else { continue }
            let to = Self.alone(base)
            guard !Self.close(was, to, zoom) else { continue }
            put(id, was.blended(to: to, k))
            moving = true
        }
        drawn = next
        isMoving = moving || !next.isEmpty
        shown = out
        return out
    }

    private static func alone(_ node: Node) -> Node {
        var n = node
        n.children = []
        return n
    }

    private static func close(_ a: Node, _ b: Node, _ zoom: CGFloat) -> Bool {
        let tolerance = 0.2 / max(zoom, 0.01)
        return abs(a.frame.minX - b.frame.minX) < tolerance && abs(a.frame.minY - b.frame.minY) < tolerance
            && abs(a.frame.width - b.frame.width) < tolerance && abs(a.frame.height - b.frame.height) < tolerance
            && abs(a.rotation - b.rotation) < 0.05 && abs(a.opacity - b.opacity) < 0.005
    }

    // MARK: Under the design

    /// Where each person looks: a soft pool of light in their colour on the table, which the
    /// artboards they look at stand in.
    func drawLight(_ ctx: CGContext, room: LiveRoom, store: DocumentStore, in bounds: CGRect) {
        _ = room.beat
        step(room, store, CACurrentMediaTime())
        guard !lights.isEmpty else { return }
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for (peer, rect) in lights where peer != room.following {
            guard let person = room.person(peer), let alpha = lightAlpha[peer], alpha > 0.01 else { continue }
            let r = store.viewport.toView(rect)
            let reach = r.insetBy(dx: -r.width * 0.2, dy: -r.height * 0.2)
            guard reach.intersects(bounds) else { continue }
            // Light, not shade: it brightens the table in their colour, as a lamp would.
            let strength = (dark ? 0.22 : 0.55) * alpha
            let colors = [person.pencil.cgColor(strength), person.pencil.cgColor(strength * 0.5), person.pencil.cgColor(0)] as CFArray
            guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1]) else { continue }
            ctx.saveGState()
            ctx.setBlendMode(dark ? .plusLighter : .screen)
            ctx.translateBy(x: r.midX, y: r.midY)
            ctx.scaleBy(x: max(r.width, 1) * 0.62, y: max(r.height, 1) * 0.62)
            ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
            ctx.restoreGState()
        }
    }

    // MARK: Over the design

    func draw(_ ctx: CGContext, room: LiveRoom, store: DocumentStore, in bounds: CGRect, scale: CGFloat) {
        _ = room.beat
        let now = CACurrentMediaTime()
        step(room, store, now)
        let doc = shown ?? store.doc
        let vp = store.viewport
        drawDeveloping(ctx, room, store, doc, vp, now, bounds)
        drawGlows(ctx, room, doc, vp, now, bounds)
        drawSelections(ctx, room, doc, vp, bounds)
        drawWinks(ctx, room, vp, now)
        for (peer, hand) in hands.sorted(by: { $0.key < $1.key }) where hand.alpha > 0.01 {
            guard let person = room.person(peer) else { continue }
            let p = room.presence[peer]
            let at = vp.toView(hand.at)
            guard bounds.insetBy(dx: -40, dy: -40).contains(at) else { continue }
            drawHand(ctx, at: at, tool: p?.doing == .typing ? "text" : p?.tool ?? "select", pencil: person.pencil, alpha: hand.alpha)
            if hand.tag > 0.01 { drawTag(ctx, person.name, at: at, pencil: person.pencil, alpha: hand.alpha * hand.tag, lift: 1 - hand.tag) }
        }
        drawCrop(ctx, in: bounds)
    }

    private func outline(of id: UUID, in doc: BezzleDocument, _ vp: Viewport) -> [CGPoint]? {
        guard let node = doc.node(id) else { return nil }
        let points: [CGPoint]
        let eye = doc.eye(forParentOf: id)
        if node.kind == .line {
            let (a, b) = node.lineEnds
            let c = CGPoint(x: node.frame.midX, y: node.frame.midY)
            points = [a, b].map { Perspective.shown(Geometry.rotated($0, about: c, by: node.rotation), of: node, eye: eye) }
        } else {
            points = Perspective.corners(of: node, eye: eye)
        }
        return points.map { vp.toView(doc.shown($0, inParentOf: id)) }
    }

    private func path(_ points: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: points)
        if points.count > 2 { p.closeSubpath() }
        return p
    }

    /// What each person holds, outlined in their pencil, with their initial on a flag at its corner.
    private func drawSelections(_ ctx: CGContext, _ room: LiveRoom, _ doc: BezzleDocument, _ vp: Viewport, _ bounds: CGRect) {
        for person in room.people {
            guard let p = room.presence[person.id], !p.selection.isEmpty else { continue }
            ctx.saveGState()
            ctx.setStrokeColor(person.pencil.cgColor(p.away ? 0.45 : 0.95))
            ctx.setLineWidth(1.25)
            var box: CGRect?
            for id in p.selection {
                guard let points = outline(of: id, in: doc, vp) else { continue }
                ctx.addPath(path(points))
                ctx.strokePath()
                let b = CGRect(points: points)
                box = box?.union(b) ?? b
            }
            ctx.restoreGState()
            guard let box, box.intersects(bounds) else { continue }
            drawFlag(ctx, person, at: CGPoint(x: box.minX, y: box.minY), away: p.away)
        }
    }

    private func drawFlag(_ ctx: CGContext, _ person: LiveRoom.Person, at corner: CGPoint, away: Bool) {
        let text = person.initial as NSString
        let font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
        let size = text.size(withAttributes: [.font: font])
        let r = CGRect(x: corner.x - 0.6, y: corner.y - 15, width: max(15, size.width + 8), height: 15)
        let flag = CGMutablePath()
        flag.addRoundedRect(in: r, cornerWidth: 3.5, cornerHeight: 3.5)
        ctx.saveGState()
        ctx.setAlpha(away ? 0.5 : 1)
        ctx.addPath(flag)
        ctx.setFillColor(person.pencil.cgColor)
        ctx.fillPath()
        text.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: [.font: font, .foregroundColor: NSColor.white])
        ctx.restoreGState()
    }

    // MARK: Pictures on their way

    /// The layers showing pictures still on their way, worked out again only as the design or
    /// those pictures change.
    private var developingLayers: (version: Int, names: Set<String>, layers: [(id: UUID, name: String)]) = (-1, [], [])

    private func layersDeveloping(_ room: LiveRoom, _ store: DocumentStore, _ doc: BezzleDocument) -> [(id: UUID, name: String)] {
        let names = Set(room.developing.keys)
        guard !names.isEmpty else { return [] }
        if developingLayers.version == store.version, developingLayers.names == names { return developingLayers.layers }
        var out: [(UUID, String)] = []
        func visit(_ n: Node) {
            if !n.hidden, n.kind != .text, n.fill.on, let image = n.fill.image, names.contains(image.shown) { out.append((n.id, image.shown)) }
            n.children.forEach(visit)
        }
        doc.nodes.forEach(visit)
        developingLayers = (store.version, names, out)
        return out
    }

    /// A picture on its way develops as a photograph does: from its glimpse, milky and grainy,
    /// its colours coming slowly; with no glimpse, as paper not yet exposed. Once it is here, it
    /// is drawn into focus, the glimpse fading off it as the grain goes.
    private func drawDeveloping(_ ctx: CGContext, _ room: LiveRoom, _ store: DocumentStore, _ doc: BezzleDocument,
                                _ vp: Viewport, _ now: CFTimeInterval, _ bounds: CGRect) {
        developingArea = nil
        for (id, name) in layersDeveloping(room, store, doc) {
            guard let d = room.developing[name], let node = doc.node(id), let image = node.fill.image else { continue }
            let o = doc.parentOrigin(of: id)
            let size = node.frame.size
            let place = CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
                .concatenating(CGAffineTransform(rotationAngle: Geometry.radians(node.rotation)))
                .concatenating(CGAffineTransform(translationX: o.x + node.frame.midX, y: o.y + node.frame.midY))
                .concatenating(CGAffineTransform(translationX: -vp.origin.x, y: -vp.origin.y))
                .concatenating(CGAffineTransform(scaleX: vp.zoom, y: vp.zoom))
            var t = place
            guard let outline = Renderer.outline(of: node).copy(using: &t), outline.boundingBoxOfPath.intersects(bounds) else { continue }
            let box = outline.boundingBoxOfPath
            let waited = now - d.since
            if d.arrived == nil { developingArea = developingArea?.union(box) ?? box }
            // How far it has come into focus, once it is here.
            let focus = d.arrived.map { CGFloat(min(max((now - $0) / Self.focusing, 0), 1)) } ?? 0
            // Gently out of the blur, then surely into focus.
            let leaving = 1 - focus * focus * (3 - 2 * focus)
            let opacity = CGFloat(node.opacity)
            ctx.saveGState()
            if let parent = doc.parent(of: id), let mask = Mask.outline(of: parent.id, in: doc) {
                var view = CGAffineTransform(translationX: -vp.origin.x, y: -vp.origin.y).concatenating(CGAffineTransform(scaleX: vp.zoom, y: vp.zoom))
                if let clip = mask.copy(using: &view) {
                    ctx.addPath(clip)
                    ctx.clip()
                }
            }
            ctx.addPath(outline)
            ctx.clip(using: node.evenOdd == true ? .evenOdd : .winding)
            // Each drawn straight onto the picture, so the grain and the light mix with it.

            if let standIn = d.standIn {
                // Coming into focus: the glimpse, drawn where the picture is, fading off it.
                if d.arrived != nil, leaving > 0.001 {
                    ctx.saveGState()
                    ctx.setAlpha(leaving * opacity)
                    ctx.concatenate(place)
                    let rect = Renderer.imageRect(image, in: size)
                    ctx.interpolationQuality = .high
                    ctx.translateBy(x: rect.midX, y: rect.midY)
                    ctx.scaleBy(x: image.flippedX == true ? -1 : 1, y: image.flippedY == true ? 1 : -1)
                    ctx.draw(Developer.developed(standIn, image.develop), in: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height))
                    ctx.restoreGState()
                }
                // Milky at first, clearing as it develops, never quite clear until it is here, and
                // breathing slowly while it waits, as a print does in a tray rocked gently.
                let breath = 0.035 * (1 - cos(2 * .pi * waited / 3.4)) / 2
                let milk = (0.1 + 0.5 * exp(-waited / 1.5) + breath) * leaving * opacity
                ctx.setFillColor(Self.paper.copy(alpha: milk) ?? Self.paper)
                ctx.fill(box)
            } else {
                // Paper not yet exposed, which the picture develops out of once it comes.
                ctx.setFillColor(Self.paper.copy(alpha: pow(leaving, 1.4) * opacity) ?? Self.paper)
                ctx.fill(box)
            }
            // A little light at the moment it comes into focus.
            if d.arrived != nil {
                ctx.setBlendMode(.screen)
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.16 * sin(.pi * focus) * opacity))
                ctx.fill(box)
                ctx.setBlendMode(.normal)
            }
            drawGrain(ctx, in: box, alpha: 0.2 * leaving * opacity, now: now)
            ctx.restoreGState()
        }
    }

    /// Photographic paper, a warm white.
    private static let paper = CGColor(srgbRed: 0.955, green: 0.94, blue: 0.91, alpha: 1)

    /// Film grain, moving a dozen times a second for as long as the picture is on its way.
    private func drawGrain(_ ctx: CGContext, in box: CGRect, alpha: CGFloat, now: CFTimeInterval) {
        guard alpha > 0.005, let grain = Self.grain else { return }
        let frame = Int(now * 12)
        var r = UInt64(truncatingIfNeeded: frame) &* 0x9E37_79B9_7F4A_7C15
        r ^= r >> 29
        let dx = CGFloat(r % 97), dy = CGFloat((r >> 8) % 89)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setBlendMode(.overlay)
        let side = CGFloat(Self.grainSide) / 2
        ctx.draw(grain, in: CGRect(x: box.minX - dx, y: box.minY - dy, width: side, height: side), byTiling: true)
        ctx.restoreGState()
    }

    private static let grainSide = 192

    /// Noise about a mid grey, which overlaid leaves the picture as it is but for its grain.
    private static let grain: CGImage? = {
        let side = grainSide
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        var r: UInt64 = 0x2545_F491_4F6C_DD1D
        for i in 0..<(side * side) {
            r ^= r << 13; r ^= r >> 7; r ^= r << 17
            // Two draws averaged: softer than white noise, as grain is.
            let a = Int(r & 0xFF), b = Int((r >> 8) & 0xFF)
            let v = UInt8(clamping: 128 + ((a + b) / 2 - 128) * 3 / 2)
            bytes[i * 4] = v; bytes[i * 4 + 1] = v; bytes[i * 4 + 2] = v
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()

    /// Fresh ink: what someone just changed glows in their pencil and fades.
    private func drawGlows(_ ctx: CGContext, _ room: LiveRoom, _ doc: BezzleDocument, _ vp: Viewport, _ now: CFTimeInterval, _ bounds: CGRect) {
        for glow in room.glows {
            let t = (now - glow.time) / 1.4
            guard t < 1, let points = outline(of: glow.id, in: doc, vp) else { continue }
            let shape = path(points)
            guard shape.boundingBoxOfPath.insetBy(dx: -12, dy: -12).intersects(bounds) else { continue }
            let fade = CGFloat(pow(1 - max(t, 0), 2))
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.setFillColor(glow.pencil.cgColor(0.09 * fade))
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 10, color: glow.pencil.cgColor(0.9 * fade))
            ctx.addPath(shape)
            ctx.setStrokeColor(glow.pencil.cgColor(0.85 * fade))
            ctx.setLineWidth(2)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// Where someone shook their pointer, circled by hand in their pencil, as one rings something
    /// on a printout for whoever reads it next. It stays a moment, then fades like graphite rubbed out.
    private func drawWinks(_ ctx: CGContext, _ room: LiveRoom, _ vp: Viewport, _ now: CFTimeInterval) {
        for wink in room.winks {
            let color: (CGFloat) -> CGColor
            if wink.by == LiveRoom.selfID {
                color = { CanvasInk.pencil.withAlphaComponent($0).cgColor }
            } else if let person = room.person(wink.by) {
                color = { person.pencil.cgColor($0) }
            } else { continue }
            let (drawn, alpha) = PencilLoop.shown(at: now - wink.time)
            guard drawn > 0, alpha > 0 else { continue }
            let c = vp.toView(wink.at)
            let points = PencilLoop.points(seed: UInt64(bitPattern: Int64(wink.time * 1000)), radius: 30)
            let last = Int(Double(points.count - 1) * drawn)
            guard last >= 1 else { continue }
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: c.y)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            // A pale rim under the line keeps it clear on dark work and light alike. Each is
            // drawn whole and then made see-through, so the pieces never darken where they meet.
            for pass in 0..<2 {
                ctx.saveGState()
                ctx.setAlpha(CGFloat(alpha) * (pass == 0 ? 0.5 : 0.94))
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.setStrokeColor(pass == 0 ? CGColor(gray: 1, alpha: 1) : color(1))
                for i in 1...last {
                    let w = PencilLoop.width(at: Double(i) / Double(points.count - 1), 2.6)
                    ctx.setLineWidth(pass == 0 ? w + 2.4 : w)
                    ctx.move(to: points[i - 1])
                    ctx.addLine(to: points[i])
                    ctx.strokePath()
                }
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
            ctx.restoreGState()
        }
    }

    /// Someone's hand: the tool they hold, in their pencil, rimmed in white so it reads on anything.
    private func drawHand(_ ctx: CGContext, at p: CGPoint, tool: String, pencil: Pencil, alpha: CGFloat) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: p.x, y: p.y)
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2.5, color: CGColor(gray: 0, alpha: 0.28))
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        switch tool {
        case "text":
            let beam = CGMutablePath()
            beam.move(to: CGPoint(x: -3, y: -8)); beam.addQuadCurve(to: CGPoint(x: 0, y: -6.5), control: CGPoint(x: -1, y: -8))
            beam.addQuadCurve(to: CGPoint(x: 3, y: -8), control: CGPoint(x: 1, y: -8))
            beam.move(to: CGPoint(x: 0, y: -6.5)); beam.addLine(to: CGPoint(x: 0, y: 6.5))
            beam.move(to: CGPoint(x: -3, y: 8)); beam.addQuadCurve(to: CGPoint(x: 0, y: 6.5), control: CGPoint(x: -1, y: 8))
            beam.addQuadCurve(to: CGPoint(x: 3, y: 8), control: CGPoint(x: 1, y: 8))
            stroke(ctx, beam, pencil)
        case "artboard", "rectangle", "ellipse", "line":
            let cross = CGMutablePath()
            cross.move(to: CGPoint(x: 0, y: -8)); cross.addLine(to: CGPoint(x: 0, y: -2.5))
            cross.move(to: CGPoint(x: 0, y: 2.5)); cross.addLine(to: CGPoint(x: 0, y: 8))
            cross.move(to: CGPoint(x: -8, y: 0)); cross.addLine(to: CGPoint(x: -2.5, y: 0))
            cross.move(to: CGPoint(x: 2.5, y: 0)); cross.addLine(to: CGPoint(x: 8, y: 0))
            stroke(ctx, cross, pencil)
        case "pen":
            // A nib, its point where the pointer is.
            let nib = CGMutablePath()
            nib.move(to: .zero)
            nib.addLine(to: CGPoint(x: 4.2, y: 9.5))
            nib.addLine(to: CGPoint(x: 9.5, y: 14.8))
            nib.addLine(to: CGPoint(x: 14.8, y: 9.5))
            nib.addLine(to: CGPoint(x: 9.5, y: 4.2))
            nib.closeSubpath()
            fill(ctx, nib, pencil)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            let slit = CGMutablePath()
            slit.move(to: CGPoint(x: 1.2, y: 1.2)); slit.addLine(to: CGPoint(x: 6.6, y: 6.6))
            ctx.addPath(slit)
            ctx.setStrokeColor(.white)
            ctx.setLineWidth(1)
            ctx.strokePath()
        default:
            let arrow = CGMutablePath()
            arrow.move(to: .zero)
            arrow.addLine(to: CGPoint(x: 0, y: 15.5))
            arrow.addLine(to: CGPoint(x: 3.9, y: 11.9))
            arrow.addLine(to: CGPoint(x: 6.6, y: 18))
            arrow.addLine(to: CGPoint(x: 9.1, y: 16.9))
            arrow.addLine(to: CGPoint(x: 6.5, y: 10.9))
            arrow.addLine(to: CGPoint(x: 11.8, y: 10.9))
            arrow.closeSubpath()
            fill(ctx, arrow, pencil)
        }
        ctx.restoreGState()
    }

    private func fill(_ ctx: CGContext, _ shape: CGPath, _ pencil: Pencil) {
        ctx.addPath(shape)
        ctx.setStrokeColor(.white)
        ctx.setLineWidth(2.6)
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(shape)
        ctx.setFillColor(pencil.cgColor)
        ctx.fillPath()
    }

    private func stroke(_ ctx: CGContext, _ shape: CGPath, _ pencil: Pencil) {
        ctx.addPath(shape)
        ctx.setStrokeColor(.white)
        ctx.setLineWidth(4)
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(shape)
        ctx.setStrokeColor(pencil.cgColor)
        ctx.setLineWidth(1.8)
        ctx.strokePath()
    }

    private static let tagFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    /// The person's name beside their hand, while they start moving, work, or are close to yours.
    private func drawTag(_ ctx: CGContext, _ name: String, at p: CGPoint, pencil: Pencil, alpha: CGFloat, lift: CGFloat) {
        let text = name as NSString
        let size = text.size(withAttributes: [.font: Self.tagFont])
        let r = CGRect(x: p.x + 11, y: p.y + 17 + lift * 5, width: size.width + 14, height: 19)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        let pill = CGMutablePath()
        pill.addRoundedRect(in: r, cornerWidth: 9.5, cornerHeight: 9.5)
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: CGColor(gray: 0, alpha: 0.18))
        ctx.addPath(pill)
        ctx.setFillColor(pencil.cgColor)
        ctx.fillPath()
        text.draw(at: CGPoint(x: r.minX + 7, y: r.midY - size.height / 2), withAttributes: [.font: Self.tagFont, .foregroundColor: NSColor.white])
        ctx.restoreGState()
    }

    /// Crop marks in the corners of the canvas, in the pencil of the person it goes along with,
    /// coming in from outside as it starts.
    private func drawCrop(_ ctx: CGContext, in bounds: CGRect) {
        guard crop > 0.01, let person = cropPerson else { return }
        // Clear of the rulers along the top and left.
        let inset = 12 + (1 - crop) * 28, arm: CGFloat = 22, ruler: CGFloat = Helpers.shared.rulers ? Rulers.thickness : 0
        let b = CGRect(x: bounds.minX + inset + ruler, y: bounds.minY + inset + ruler,
                       width: bounds.width - inset * 2 - ruler, height: bounds.height - inset * 2 - ruler)
        let marks = CGMutablePath()
        for (corner, dx, dy) in [(CGPoint(x: b.minX, y: b.minY), 1.0, 1.0), (CGPoint(x: b.maxX, y: b.minY), -1.0, 1.0),
                                 (CGPoint(x: b.minX, y: b.maxY), 1.0, -1.0), (CGPoint(x: b.maxX, y: b.maxY), -1.0, -1.0)] {
            marks.move(to: CGPoint(x: corner.x + arm * dx, y: corner.y))
            marks.addLine(to: corner)
            marks.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
        }
        ctx.saveGState()
        ctx.setAlpha(crop)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(marks)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(5)
        ctx.strokePath()
        ctx.addPath(marks)
        ctx.setStrokeColor(person.pencil.cgColor)
        ctx.setLineWidth(2.5)
        ctx.strokePath()
        ctx.restoreGState()
        // Their name along the foot, beside the mark at the bottom left.
        drawTag(ctx, person.name, at: CGPoint(x: b.minX + arm - 3, y: b.maxY - 26.5), pencil: person.pencil, alpha: crop, lift: 0)
    }
}

private extension CGRect {
    init(points: [CGPoint]) {
        let xs = points.map(\.x), ys = points.map(\.y)
        self.init(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }
}
