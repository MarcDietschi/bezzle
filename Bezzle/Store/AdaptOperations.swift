import AppKit
import Vision

extension Adapting {
    /// What the pictures on an artboard show, as the Mac's Vision finds them.
    static func pictures(of board: Node, assets: Assets?) -> AdaptPictures {
        AdaptPictures(focus: focus(of: board, assets: assets, now: true), shapes: shapes(of: board, assets: assets), cores: cores(of: board, assets: assets))
    }

    /// An artboard at a new size, its design laid out again with what its pictures show.
    static func resized(_ board: Node, to size: CGSize, assets: Assets?, remembering: Bool = true) -> Node {
        resized(board, to: size, pictures: { pictures(of: $0, assets: assets) }, remembering: remembering)
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

extension Adapting.Session {
    /// An artboard being resized by a drag, with what the Mac sees in its pictures.
    convenience init?(_ board: Node, assets: Assets?) {
        self.init(board, pictures: { Adapting.pictures(of: $0, assets: assets) })
    }
}

extension DocumentStore {
    /// Artboards at new sizes: each design laid out again for its new size, as one step.
    func resizeArtboards(_ ids: [UUID], _ action: LocalizedStringResource = "Resize Artboard", to size: (Node) -> CGSize) {
        var laid: [UUID: Node] = [:]
        let assets = assets
        edit(action) { doc in laid = Adapting.resize(&doc, ids, to: size) { Adapting.pictures(of: $0, assets: assets) } }
        Adapting.finish(laid, in: doc)
    }

    /// The artboard as it would be at `size`, its design laid out again: for showing what a size
    /// would do before it is chosen.
    func adaptedPreview(of id: UUID, to size: CGSize) -> ((inout BezzleDocument) -> Void)? {
        let assets = assets
        return Adapting.preview(doc, of: id, to: size) { Adapting.pictures(of: $0, assets: assets) }
    }
}
