import AppKit
import Vision

/// Laying an artboard's design out again when it takes a new size; see `Adapt`.
@MainActor
enum Adapting {
    /// Posted with the artboards (`ids`) whose layers were just laid out again, for the canvas to
    /// move them there rather than jump.
    static let laidOut = Notification.Name("Bezzle.adaptLaidOut")

    /// The design as it was made, by artboard, and the artboard as it was last laid out from it.
    /// While the artboard is left as it was laid out, its next size is laid out from the design as
    /// it was made, so that going back to that size gives the design back exactly.
    private static var made: [UUID: (source: Node, laid: Node)] = [:]
    /// The artboards remembered, the one laid out last at the end; only so many are kept.
    private static var order: [UUID] = []
    static let kept = 64
    static var remembered: Int { made.count }

    /// Whether an artboard's design is laid out again when it changes size: not a carousel, whose
    /// slides are added and taken away, nor one told to keep its layers where they are.
    static func adapts(_ board: Node) -> Bool {
        board.isArtboard && !board.isCarousel && board.pinsLayers != true && !board.children.isEmpty
    }

    /// The design to lay an artboard out from: as it was made, while it is as it was last laid out.
    static func source(of board: Node) -> Node {
        guard let kept = made[board.id], kept.laid.frame.size == board.frame.size,
              kept.laid.layers(of: nil) == board.layers(of: nil) else { return board }
        var s = board
        s.frame.size = kept.source.frame.size
        // Its posts as they were too, while nothing in them has changed since.
        if kept.laid.children == board.children {
            s.children = kept.source.children
            return s
        }
        // Else a deck's posts are as they are now: only the design behind them is laid out.
        let design = Dictionary(kept.source.layers(of: nil).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard kept.source.layers(of: nil).count == board.layers(of: nil).count else { return board }
        s.children = board.children.map { c in c.post == nil ? design[c.id] ?? c : c }
        return s
    }

    /// Notes that `laid` was laid out from `source`, to lay it out from that again next time.
    static func remember(source: Node, laid: Node) {
        order.removeAll { $0 == laid.id }
        if source.frame.size == laid.frame.size && source.layers(of: nil) == laid.layers(of: nil) {
            made[laid.id] = nil
        } else {
            made[laid.id] = (source, laid)
            order.append(laid.id)
            while order.count > kept { made[order.removeFirst()] = nil }
        }
    }

    /// An artboard at a new size: its design laid out again for it, or its layers left where they
    /// are on it, from its top left.
    static func resized(_ board: Node, to size: CGSize, assets: Assets? = nil, remembering: Bool = true) -> Node {
        var out = board
        out.frame.size = size
        guard adapts(board), size != board.frame.size, size.width >= 1, size.height >= 1 else { return out }
        let source = source(of: board)
        let plan = Adapt.plan(source, mode: Adapt.mode(of: source, to: size), focus: focus(of: source, assets: assets, now: true),
                              shapes: shapes(of: source, assets: assets), cores: cores(of: source, assets: assets))
        // What a post keeps of its own goes from the design as it was made, never from a step on
        // the way, so nothing creeps.
        out.children = merged(Adapt.compose(plan, to: size).board, into: source, from: source)
        if remembering { remember(source: source, laid: out) }
        return out
    }

    /// What lies on `board` with the design's layers as `laid` has them, and a deck's posts as
    /// `board` has them, for the deck to make them again from the design. What a post's layer
    /// keeps of its own, its place or its type, goes as the same layer of the design went from
    /// `original`, the artboard as it was before it took its new size.
    static func merged(_ laid: Node, into board: Node, from original: Node? = nil) -> [Node] {
        let original = original ?? board
        let design = Dictionary(laid.layers(of: nil).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let then = Dictionary(original.layers(of: nil).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let was = Dictionary(original.children.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return board.children.map { c in
            guard let post = c.post else { return design[c.id] ?? c }
            let twin = c.id.mixed(Deck.key(post))
            guard let old = then[twin], let new = design[twin], let own = was[c.id] else { return c }
            return carried(c, own: own, from: old, to: new, key: Deck.key(post))
        }
    }

    /// A post's layer, `now`, with what it keeps of its own as it was (`own`) carried as its
    /// twin in the design went from `old` to `new`; and so for what it holds.
    private static func carried(_ now: Node, own: Node, from old: Node, to new: Node, key: RepeatGrid.Key) -> Node {
        var n = now
        let kept = Set(own.own ?? [])
        if kept.contains("frame"), old.frame.width > 0 || old.frame.height > 0 {
            var f = Geometry.map(own.frame, from: old.frame, to: new.frame)
            if old.frame.width <= 0 { f.size.width = own.frame.width }
            if old.frame.height <= 0 { f.size.height = own.frame.height }
            n.frame = f
        }
        if kept.contains("style") || kept.contains("spans"), let a = old.style?.size, let b = new.style?.size, a > 0, abs(b / a - 1) > 0.0001 {
            n.style = own.style
            n.spans = own.spans
            n.scaleType(by: b / a)
        }
        guard !now.children.isEmpty else { return n }
        let olds = Dictionary(old.children.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let news = Dictionary(new.children.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let owns = Dictionary(own.children.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        n.children = now.children.map { c in
            let twin = c.id.mixed(key)
            guard let o = olds[twin], let w = news[twin], let k = owns[c.id] else { return c }
            return carried(c, own: k, from: o, to: w, key: key)
        }
        return n
    }

    /// Tells the canvas these artboards were just laid out again.
    static func announce(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        NotificationCenter.default.post(name: laidOut, object: nil, userInfo: ["ids": ids])
    }

    // MARK: Dragging

    /// An artboard being resized by a drag: its design read once, and laid out at each size the
    /// drag reaches, keeping the arrangement it is in unless another suits clearly better.
    final class Session {
        let id: UUID
        let source: Node
        let plan: Adapt.Plan
        private(set) var arrangement: Adapt.Arrangement = .original
        private(set) var last: Adapt.Result?

        init?(_ board: Node, assets: Assets?) {
            guard Adapting.adapts(board) else { return nil }
            id = board.id
            source = Adapting.source(of: board)
            plan = Adapt.plan(source, focus: Adapting.focus(of: source, assets: assets, now: true), shapes: Adapting.shapes(of: source, assets: assets),
                              cores: Adapting.cores(of: source, assets: assets))
        }

        /// The design laid out at `size`, and whether it is arranged another way than a moment ago.
        func compose(_ size: CGSize) -> (result: Adapt.Result, rearranged: Bool) {
            let r = Adapt.compose(plan, to: size, keeping: arrangement)
            let rearranged = r.arrangement != arrangement
            arrangement = r.arrangement
            last = r
            return (r, rearranged)
        }
    }

    // MARK: What pictures show

    /// Where in each picture on the artboard what it shows lies, for those known so far. Those
    /// not yet known are looked at away from here, for next time; or `now`, for a picture that
    /// takes a fair part of the artboard, as one being cropped anew must be.
    static func focus(of board: Node, assets: Assets?, now: Bool = false) -> [String: CGPoint] {
        guard let assets else { return [:] }
        var names: [String: CGFloat] = [:]
        func visit(_ n: Node) {
            if let image = n.fill.image, image.mode == .cover { names[image.asset] = max(names[image.asset] ?? 0, n.frame.intersection(CGRect(origin: .zero, size: board.frame.size)).area) }
            n.children.forEach(visit)
        }
        board.children.forEach(visit)
        var out: [String: CGPoint] = [:]
        let area = board.frame.width * board.frame.height
        for (name, covers) in names {
            if let p = PictureFocus.known(name) {
                out[name] = p
            } else if now, covers >= area * 0.1, let p = PictureFocus.findNow(name, in: assets) {
                out[name] = p
            } else {
                PictureFocus.find(name, in: assets)
            }
        }
        return out
    }

    /// Where in each picture with a transparent ground on the artboard what it shows lies, as
    /// `Adapt.plan` takes it: a person cut out of a photo is the person.
    static func shapes(of board: Node, assets: Assets?) -> [String: CGRect] {
        guard let assets else { return [:] }
        var names = Set<String>()
        func visit(_ n: Node) {
            if let image = n.fill.image { names.insert(image.asset) }
            n.children.forEach(visit)
        }
        board.children.forEach(visit)
        var out: [String: CGRect] = [:]
        for name in names { if let r = PictureFocus.shape(name, in: assets) { out[name] = r } }
        return out
    }

    /// Where most of what each cut-out picture on the artboard shows lies: a person's body.
    static func cores(of board: Node, assets: Assets?) -> [String: CGRect] {
        guard let assets else { return [:] }
        var names = Set<String>()
        func visit(_ n: Node) {
            if let image = n.fill.image { names.insert(image.asset) }
            n.children.forEach(visit)
        }
        board.children.forEach(visit)
        var out: [String: CGRect] = [:]
        for name in names { if let r = PictureFocus.core(name, in: assets) { out[name] = r } }
        return out
    }

    /// Starts looking at what the pictures on an artboard show, so that it is known by the time
    /// the artboard is resized.
    static func prepare(_ board: Node, assets: Assets?) {
        _ = focus(of: board, assets: assets)
    }
}

/// Where in a picture what it shows lies: the middle of what draws the eye, as the Mac's own
/// Vision finds it, 0…1 across and down the picture.
nonisolated enum PictureFocus {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var points: [String: CGPoint] = [:]
    nonisolated(unsafe) private static var looking: Set<String> = []
    private static let queue = DispatchQueue(label: "com.erik.Bezzle.focus", qos: .utility)

    static func known(_ name: String) -> CGPoint? { lock.withLock { points[name] } }

    /// Looks at the picture here and now, once, for one that is needed at once.
    static func findNow(_ name: String, in assets: Assets) -> CGPoint? {
        if let p = known(name) { return p }
        guard let p = assets.image(name, pixels: 640).flatMap(point(in:)) else { return nil }
        lock.withLock { points[name] = p }
        return p
    }

    nonisolated(unsafe) private static var shapes: [String: (CGRect, CGRect)?] = [:]

    /// Where what a picture shows lies in it, 0…1 across and down, when its ground is
    /// transparent, as a person cut out of a photo is; nil for one that is all picture.
    static func shape(_ name: String, in assets: Assets) -> CGRect? { silhouette(name, in: assets)?.0 }

    /// Where most of what a cut-out picture shows lies: the middle of its weight, across and down,
    /// without a hand held out at its side.
    static func core(_ name: String, in assets: Assets) -> CGRect? { silhouette(name, in: assets)?.1 }

    private static func silhouette(_ name: String, in assets: Assets) -> (CGRect, CGRect)? {
        if let known = lock.withLock({ shapes[name] }) { return known }
        let found = assets.image(name, pixels: 256).flatMap(opaque)
        lock.withLock { shapes[name] = .some(found) }
        return found
    }

    /// The box round what is not transparent in a picture, 0…1 across and down; nil for one with
    /// no transparency, or with nothing in it.
    static func opaqueBounds(_ image: CGImage) -> CGRect? { opaque(image)?.0 }

    /// The box round what is not transparent in a picture, and the box holding the middle of its
    /// weight, 0…1 across and down.
    static func opaque(_ image: CGImage) -> (CGRect, CGRect)? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return nil
        default: break
        }
        let w = min(image.width, 128), h = max(1, Int((CGFloat(image.height) * CGFloat(w) / CGFloat(max(image.width, 1))).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue), let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let alpha = data.bindMemory(to: UInt8.self, capacity: w * h)
        var minX = w, minY = h, maxX = -1, maxY = -1
        var columns = [Int](repeating: 0, count: w), rows = [Int](repeating: 0, count: h)
        for y in 0..<h {
            for x in 0..<w where alpha[y * w + x] > 24 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                columns[x] += 1
                rows[y] += 1
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // The bitmap's rows run down from its top, as the picture's do.
        let r = CGRect(x: CGFloat(minX) / CGFloat(w), y: CGFloat(minY) / CGFloat(h),
                       width: CGFloat(maxX - minX + 1) / CGFloat(w), height: CGFloat(maxY - minY + 1) / CGFloat(h))
        guard r.width <= 0.96 || r.height <= 0.96 else { return nil }
        // The middle of its weight: what is left once a tenth of it is taken off either side.
        func middle(_ counts: [Int]) -> (CGFloat, CGFloat) {
            let total = counts.reduce(0, +)
            var a = 0, b = counts.count - 1, cut = 0
            while a < b, cut + counts[a] <= total / 10 { cut += counts[a]; a += 1 }
            cut = 0
            while b > a, cut + counts[b] <= total / 10 { cut += counts[b]; b -= 1 }
            return (CGFloat(a) / CGFloat(counts.count), CGFloat(b + 1) / CGFloat(counts.count))
        }
        let (x0, x1) = middle(columns), (y0, y1) = middle(rows)
        return (r, CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
    }

    /// Looks at the picture away from here, once.
    static func find(_ name: String, in assets: Assets) {
        let start = lock.withLock { () -> Bool in
            guard points[name] == nil, !looking.contains(name) else { return false }
            looking.insert(name)
            return true
        }
        guard start else { return }
        queue.async {
            let p = assets.image(name, pixels: 640).flatMap(point(in:))
            lock.withLock {
                looking.remove(name)
                if let p { points[name] = p }
            }
        }
    }

    /// What draws the eye in a picture: the salient parts Vision finds, weighed by how sure it is
    /// of each and how much it covers.
    static func point(in image: CGImage) -> CGPoint? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let result = request.results?.first, let objects = result.salientObjects, !objects.isEmpty else { return nil }
        var x = 0.0, y = 0.0, w = 0.0
        for o in objects {
            let b = o.boundingBox
            let weight = Double(max(o.confidence, 0.05)) * Double(max(b.width * b.height, 0.0001))
            x += Double(b.midX) * weight
            // Vision measures up from the bottom.
            y += Double(1 - b.midY) * weight
            w += weight
        }
        guard w > 0 else { return nil }
        return CGPoint(x: min(max(x / w, 0), 1), y: min(max(y / w, 0), 1))
    }
}

extension DocumentStore {
    /// Resizes artboards as one step, laying out each one's design again for its new size, or
    /// leaving its layers in place where it keeps them.
    func resizeArtboards(_ ids: [UUID], _ action: LocalizedStringResource = "Resize Artboard", to size: (Node) -> CGSize) {
        var laid: [UUID: Node] = [:]
        let assets = assets
        edit(action) { doc in
            for id in ids {
                doc.update(id) { b in
                    guard b.isArtboard, !b.isCarousel else { return }
                    let s = size(b)
                    guard s != b.frame.size, s.width >= 1, s.height >= 1 else { return }
                    let source = Adapting.source(of: b)
                    b = Adapting.resized(b, to: s, assets: assets)
                    laid[id] = source
                }
            }
        }
        // As the design ended up, its decks' posts made again from it.
        for (id, source) in laid { if let n = doc.node(id) { Adapting.remember(source: source, laid: n) } }
        Adapting.announce(laid.keys.filter { doc.node($0).map(Adapting.adapts) ?? false })
    }

    /// The artboard as it would be at `size`, its design laid out again: for showing what a size
    /// would do before it is chosen.
    func adaptedPreview(of id: UUID, to size: CGSize) -> ((inout BezzleDocument) -> Void)? {
        guard let b = doc.node(id), b.isArtboard, !b.isCarousel, size != b.frame.size else { return nil }
        let assets = assets
        let shown = Adapting.resized(b, to: size, assets: assets, remembering: false)
        return { doc in
            let before = doc
            doc.update(id) { $0 = shown }
            // A deck shows a post, which follows the design.
            doc.syncDecks(since: before)
        }
    }
}
