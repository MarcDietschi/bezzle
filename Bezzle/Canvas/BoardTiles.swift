import AppKit
import QuartzCore

/// Artboards kept as tiles of pictures, at about the size they are seen, so moving about a design
/// draws a few pictures rather than every layer in it, however close it is looked at.
///
/// Tiles are made a little sharper than needed, in steps of √2, so zooming a little keeps using
/// them. Each artboard also keeps a small picture of the whole of it, about a tile's worth: seen
/// smaller than that, it is drawn from that picture alone, and closer up the picture stands in,
/// stretched, wherever sharper tiles are still to be made, so nothing is ever left bare. While the
/// zoom changes, new tiles wait until it has stayed put a moment; then only tiles in sight are
/// made, as many as a frame has time for. When an artboard changes, only the tiles where it now
/// looks different are made again.
///
/// Given a `maker`, tiles are drawn away from the main thread instead, all that are wanted at
/// once, and come in while the frames go on; the pictures of whole artboards and the tiles just
/// out of sight too, even while the view moves. Only what changes as it is being changed is still
/// drawn in the frame, so that it shows at once.
@MainActor
final class BoardTiles {
    /// A tile's side, in pixels.
    static let side = 512
    static let settle: CFTimeInterval = 0.15
    private let budget = 384 << 20

    private struct Key: Hashable {
        let step: CGFloat
        let i: Int
        let j: Int
    }

    private struct Tile {
        let image: CGImage
        /// Where it lies in the artboard's own coordinates, so moving the artboard keeps it.
        let rect: CGRect
        /// Made while the artboard was changing, with its background blurs as they were before;
        /// made again once it is left alone.
        var provisional: Bool
        var used: UInt64
        /// Its own pixels' worth, even when it is cut from a larger picture it shares.
        var bytes: Int { image.width * image.height * 4 }
    }

    private typealias Cell = (i: Int, j: Int, rect: CGRect)

    private struct Board {
        /// The artboard as its tiles show it.
        var node: Node
        var tiles: [Key: Tile] = [:]
        /// When it last looked different, to tell when it is being changed.
        var changed: CFTimeInterval
        /// Where its background blurs are, which show what lies behind them.
        var backdrops: [CGRect]
        /// The step its picture of the whole of it is made at; those tiles are kept as long as it is.
        var overview: CGFloat
        var shadowPixels: CGFloat
        /// The step it is shown at. After a zoom it stays at the one before, stretched, until
        /// all it shows at the new one is ready, and then changes all at once.
        var shown: CGFloat?
        /// Counted afresh whenever it looks different, so a tile drawn away from the main thread
        /// from how it looked before is not kept.
        var version: Int
    }

    /// Draws tiles away from the main thread; without it, they are made in the frame.
    var maker: TileMaker?
    /// Told when a tile drawn away from the main thread has come, so the canvas is drawn again.
    var arrived: (() -> Void)?
    private var versions = 0

    /// What one frame drew, to find out how well the tiles keep up.
    struct Counts {
        var kept = 0, made = 0, stoodIn = 0, papered = 0, direct = 0
    }
    /// Each frame's counts, oldest first, kept only while something reads them.
    var frames: [Counts]?
    private var counts = Counts()

    private var boards: [UUID: Board] = [:]
    /// What the tiles take, leaving out the pictures of whole artboards, which are kept anyway.
    private var bytes = 0
    private var clock: UInt64 = 0
    private var step: CGFloat = 0
    private var stepSince: CFTimeInterval = 0

    /// Pixels per canvas point tiles are made at, for a canvas shown at `scale`.
    static func step(for scale: CGFloat) -> CGFloat { pow(2, ceil(log2(max(scale, 0.0001)) * 2 - 1e-9) / 2) }

    /// The step at which the whole of an artboard, its shadow included, takes about a tile's pixels.
    static func overviewStep(_ size: CGSize, shadowPixels: CGFloat) -> CGFloat {
        var k = Int((log2(CGFloat(side) / max(size.width, size.height, 1)) * 2).rounded(.up))
        func pixels(_ s: CGFloat) -> CGFloat { (size.width * s + 2 * shadowPixels) * (size.height * s + 2 * shadowPixels) }
        while k > -60, pixels(pow(2, CGFloat(k) / 2)) > CGFloat(side * side) { k -= 1 }
        return pow(2, CGFloat(k) / 2)
    }

    /// Lets every tile go, for when what they show changed without their artboards changing, as
    /// when a picture they lacked arrives.
    func forget() {
        boards = [:]
        bytes = 0
    }

    /// Has the tiles of the artboards that show a picture made again, now that it has been read at
    /// the size they needed rather than drawn at another for the time being. They show until then,
    /// and the picture of the whole artboard, which stands in for them, stays as it is: made
    /// small, any size of the picture serves it.
    func forget(showing picture: String) {
        for (id, board) in boards where board.node.shows(picture: picture) {
            for key in board.tiles.keys where key.step != board.overview { boards[id]?.tiles[key]?.provisional = true }
        }
    }

    /// Starts a frame drawn at `scale` pixels to the canvas point, forgetting artboards that are gone.
    func begin(scale: CGFloat, now: CFTimeInterval, artboards: Set<UUID>) {
        if clock > 0 { frames?.append(counts) }
        counts = Counts()
        clock += 1
        maker?.begin(ObjectIdentifier(self))
        let s = Self.step(for: scale)
        if s != step {
            step = s
            stepSince = now
        }
        for (id, board) in boards where !artboards.contains(id) {
            bytes -= board.tiles.filter { $0.key.step != board.overview }.values.reduce(0) { $0 + $1.bytes }
            boards[id] = nil
        }
    }

    /// Draws an artboard from its tiles, making those it lacks while the frame has time.
    ///
    /// `make` draws a part of the canvas into a picture at a number of pixels to the point, with
    /// background blurs as they last were when told so. `live` says a preview is moving; `still`,
    /// that the view has stayed put a moment. With a `maker`, `away` does what `make` does on
    /// another thread, for an artboard left alone. Returns whether the canvas should be drawn again
    /// soon to finish the job.
    func draw(_ board: Node, in ctx: CGContext, visible: CGRect, shadowPixels: CGFloat, now: CFTimeInterval, deadline: CFTimeInterval,
              live: Bool, still: Bool = true, make: (CGRect, CGFloat, Bool) -> CGImage?,
              away: (@Sendable (CGRect, CGFloat) -> CGImage?)? = nil) -> Bool {
        // Taken out while it is worked on, so its tiles are not copied on every change.
        var entry = boards.removeValue(forKey: board.id) ?? {
            versions += 1
            return Board(node: board, changed: -.infinity, backdrops: Damage.backdrops(of: board),
                         overview: Self.overviewStep(board.frame.size, shadowPixels: shadowPixels), shadowPixels: shadowPixels, version: versions)
        }()
        /// Whether it looks different in this very frame.
        var changedNow = false
        if entry.node != board {
            versions += 1
            entry.version = versions
            let damage = Damage.between(entry.node, board)
            forget(in: &entry, where: damage)
            entry.node = board
            entry.backdrops = Damage.backdrops(of: board)
            if damage?.isNull != true {
                entry.changed = now
                changedNow = true
            }
            // The background blurs over what changed changed too. While things move they show
            // what they showed before, which these tiles still do, so they are kept for now and
            // made again once things settle.
            if let damage, !damage.isNull {
                let behind = Damage.behind(damage, among: entry.backdrops)
                if !behind.isNull {
                    for (key, tile) in entry.tiles where tile.rect.intersects(behind) { entry.tiles[key]?.provisional = true }
                }
            }
        }
        let overview = Self.overviewStep(board.frame.size, shadowPixels: shadowPixels)
        if overview != entry.overview || shadowPixels != entry.shadowPixels {
            forget(in: &entry, where: nil)
            versions += 1
            entry.version = versions
            entry.overview = overview
            entry.shadowPixels = shadowPixels
        }
        defer {
            boards[board.id] = entry
            if bytes > budget { trim() }
        }

        let changing = live || now - entry.changed < Self.settle
        var again = false
        let seen = visible.offsetBy(dx: -board.frame.minX, dy: -board.frame.minY)
        // Seen no bigger than its picture of the whole of it, an artboard is drawn from that,
        // whatever the zoom. Closer up, that picture is what stands in for tiles to come, so it
        // is made first; it draws the whole artboard, so only while the view stays put, and not
        // while the artboard is being changed.
        let s = max(step, overview)
        let away = maker == nil ? nil : away
        // Drawn away from the main thread, it costs the frame nothing, so it is wanted even while the view moves.
        let wholeMissing = s != overview && (still || away != nil) && !changing
            && grid(entry, step: overview).contains { entry.tiles[Key(step: overview, i: $0.i, j: $0.j)] == nil }
        if wholeMissing, let away, now - entry.changed > 1 || !entry.tiles.keys.contains(where: { $0.step == overview }) {
            for cell in grid(entry, step: overview) where entry.tiles[Key(step: overview, i: cell.i, j: cell.j)] == nil {
                want(cell, step: overview, .whole, of: board, entry, away: away)
            }
            again = true
        } else if wholeMissing, now - entry.changed > 1 || !entry.tiles.keys.contains(where: { $0.step == overview }) {
            for cell in grid(entry, step: overview) where entry.tiles[Key(step: overview, i: cell.i, j: cell.j)] == nil {
                guard CACurrentMediaTime() < deadline else { again = true; break }
                if let image = make(cell.rect.offsetBy(dx: board.frame.minX, dy: board.frame.minY), overview, false) {
                    keep(Tile(image: image, rect: cell.rect, provisional: false, used: clock), at: Key(step: overview, i: cell.i, j: cell.j), in: &entry)
                    counts.made += 1
                }
            }
        }

        let cells = grid(entry, step: s, within: seen)
        guard !cells.isEmpty else { return again }
        let at = placement(of: board, margin: entry.shadowPixels / s, step: s, in: ctx)
        let settled = s == overview || now - stepSince >= Self.settle
        func usable(_ c: Cell) -> Bool { entry.tiles[Key(step: s, i: c.i, j: c.j)].map { !$0.provisional || changing } ?? false }

        if changing, let away, !changedNow, !live {
            // Changed a moment ago but not in this frame: what it lacks is not what changed, which
            // was made when it did, but what moving or zooming since brought into sight, and that
            // waits as it does for an artboard left alone, drawn away from the main thread.
            for c in cells where !usable(c) { want(c, step: s, .sight, of: board, entry, away: away) }
        } else if changing {
            // What changed shows now, all of it in sight made in one drawing: a change across many
            // tiles is drawn once, and lands on the same pixels as the tiles around it.
            let missing = cells.filter { !usable($0) }
            if !missing.isEmpty { makeTogether(missing, step: s, of: board, in: &entry, changing: true, make: make) }
            entry.shown = s
        } else if settled, let away {
            for c in cells where !usable(c) { want(c, step: s, .sight, of: board, entry, away: away) }
        } else if settled {
            for c in cells where !usable(c) {
                guard CACurrentMediaTime() < deadline else { break }
                makeTogether([c], step: s, of: board, in: &entry, changing: false, make: make)
            }
        }
        let complete = cells.allSatisfy(usable)
        if complete { entry.shown = s }
        // After a zoom, the zoom before is shown, stretched, until the new one is ready in full.
        let switching = entry.shown != s

        ctx.saveGState()
        // Without antialiasing, tiles meet without a seam, at whatever scale they are drawn.
        ctx.setShouldAntialias(false)
        ctx.interpolationQuality = s > Renderer.pixelScale(ctx) * 1.5 ? .high : .medium
        for cell in cells {
            let key = Key(step: s, i: cell.i, j: cell.j)
            let kept = entry.tiles[key]
            if !switching, let kept {
                entry.tiles[key]?.used = clock
                place(kept.image, kept.rect, at, ctx)
                counts.kept += 1
                if kept.provisional { again = true }
                continue
            }
            again = true
            // Meanwhile: the picture of the whole artboard, and what there is of the nearest
            // other zoom over it, stretched.
            let stand = standIns(entry, for: cell.rect, step: s)
            if !stand.isEmpty {
                counts.stoodIn += 1
                ctx.saveGState()
                ctx.clip(to: cell.rect.offsetBy(dx: at.x, dy: at.y))
                // Where the stand-ins leave gaps, the paper.
                if !stand.contains(where: { $0.rect.contains(cell.rect) }) { paper(board, under: cell.rect, at, ctx) }
                ctx.interpolationQuality = .medium
                for tile in stand { place(tile.image, tile.rect, at, ctx) }
                ctx.restoreGState()
            } else {
                paper(board, under: cell.rect, at, ctx)
                counts.papered += 1
            }
        }
        ctx.restoreGState()

        // With time to spare and nothing moving, the tiles just out of sight, so moving a little
        // finds them ready; away from the main thread, whenever the artboard is left alone.
        if let away, settled, !changing {
            let side = CGFloat(Self.side) / s
            for c in grid(entry, step: s, within: seen.insetBy(dx: -side, dy: -side)) where entry.tiles[Key(step: s, i: c.i, j: c.j)] == nil {
                want(c, step: s, .around, of: board, entry, away: away)
                again = true
            }
        } else if complete, still, !changing {
            let side = CGFloat(Self.side) / s
            for c in grid(entry, step: s, within: seen.insetBy(dx: -side, dy: -side)) where entry.tiles[Key(step: s, i: c.i, j: c.j)] == nil {
                guard CACurrentMediaTime() < deadline else {
                    again = true
                    break
                }
                makeTogether([c], step: s, of: board, in: &entry, changing: false, make: make)
            }
        }
        return again
    }

    /// Wants a tile drawn away from the main thread. It is kept when it comes if the artboard still
    /// looks as it did when it was asked for; otherwise it is wanted again as the artboard is now.
    private func want(_ c: Cell, step s: CGFloat, _ urgency: TileMaker.Urgency, of board: Node, _ entry: Board,
                      away: @escaping @Sendable (CGRect, CGFloat) -> CGImage?) {
        guard let maker else { return }
        let rect = c.rect.offsetBy(dx: board.frame.minX, dy: board.frame.minY), cell = c.rect
        let id = board.id, version = entry.version, key = Key(step: s, i: c.i, j: c.j)
        maker.want(TileMaker.Key(owner: ObjectIdentifier(self), board: id, step: s, i: c.i, j: c.j), urgency, draw: { away(rect, s) }) { [weak self] image in
            guard let self, let image, var entry = self.boards.removeValue(forKey: id) else { return }
            defer { self.boards[id] = entry }
            guard entry.version == version else { return }
            self.keep(Tile(image: image, rect: cell, provisional: false, used: self.clock), at: key, in: &entry)
            self.counts.made += 1
            self.arrived?()
        }
    }

    /// Makes tiles of one step together, from one drawing of the part of the artboard they cover,
    /// so that what spans many of them is drawn once. Tiles far apart are drawn each on its own.
    private func makeTogether(_ cells: [Cell], step s: CGFloat, of board: Node, in entry: inout Board, changing: Bool,
                              make: (CGRect, CGFloat, Bool) -> CGImage?) {
        func kept(_ c: Cell, _ image: CGImage) {
            let provisional = changing && entry.backdrops.contains { $0.intersects(c.rect) }
            keep(Tile(image: image, rect: c.rect, provisional: provisional, used: clock), at: Key(step: s, i: c.i, j: c.j), in: &entry)
            counts.made += 1
        }
        let union = cells.reduce(CGRect.null) { $0.union($1.rect) }
        let covered = cells.reduce(CGFloat(0)) { $0 + $1.rect.width * $1.rect.height }
        if cells.count > 1, union.width * union.height <= covered * 2, union.width * union.height * s * s <= 40_000_000,
           let whole = make(union.offsetBy(dx: board.frame.minX, dy: board.frame.minY), s, changing) {
            for c in cells {
                // Each cell's own pixels of the one picture, counted from its top left.
                let part = CGRect(x: ((c.rect.minX - union.minX) * s).rounded(), y: ((c.rect.minY - union.minY) * s).rounded(),
                                  width: (c.rect.width * s).rounded(), height: (c.rect.height * s).rounded())
                if let image = whole.cropping(to: part) { kept(c, image) }
            }
            return
        }
        for c in cells {
            if let image = make(c.rect.offsetBy(dx: board.frame.minX, dy: board.frame.minY), s, changing) { kept(c, image) }
        }
    }

    /// The tiles an artboard is cut into at a step, where they lie in its coordinates: all of
    /// them, or those that show some of `seen`. Each covers whole pixels of its picture at that step.
    private func grid(_ entry: Board, step s: CGFloat, within seen: CGRect? = nil) -> [Cell] {
        let margin = entry.shadowPixels / s
        let area = CGRect(origin: .zero, size: entry.node.frame.size).insetBy(dx: -margin, dy: -margin)
        let part = seen.map { $0.intersection(area) } ?? area
        guard !part.isNull, part.width > 0, part.height > 0 else { return [] }
        let side = CGFloat(Self.side) / s
        let columns = Int((area.width * s).rounded(.up)), rows = Int((area.height * s).rounded(.up))
        let i0 = max(0, Int(((part.minX - area.minX) / side).rounded(.down))), i1 = min((columns - 1) / Self.side, Int(((part.maxX - area.minX) / side).rounded(.up)) - 1)
        let j0 = max(0, Int(((part.minY - area.minY) / side).rounded(.down))), j1 = min((rows - 1) / Self.side, Int(((part.maxY - area.minY) / side).rounded(.up)) - 1)
        guard i0 <= i1, j0 <= j1 else { return [] }
        var out: [Cell] = []
        for j in j0...j1 {
            for i in i0...i1 {
                let w = min(Self.side, columns - i * Self.side), h = min(Self.side, rows - j * Self.side)
                out.append((i, j, CGRect(x: area.minX + CGFloat(i) * side, y: area.minY + CGFloat(j) * side, width: CGFloat(w) / s, height: CGFloat(h) / s)))
            }
        }
        return out
    }

    /// Where an artboard's tiles are put. Drawn at the step they were made at, they go on whole
    /// pixels, so they are copied rather than resampled half a pixel over, which would soften every edge.
    private func placement(of board: Node, margin: CGFloat, step s: CGFloat, in ctx: CGContext) -> CGPoint {
        let origin = board.frame.origin
        guard abs(Renderer.pixelScale(ctx) - s) < 0.001 else { return origin }
        let t = ctx.userSpaceToDeviceSpaceTransform
        let corner = CGPoint(x: origin.x - margin, y: origin.y - margin).applying(t)
        let snapped = CGPoint(x: corner.x.rounded(), y: corner.y.rounded()).applying(t.inverted())
        return CGPoint(x: snapped.x + margin, y: snapped.y + margin)
    }

    private func keep(_ tile: Tile, at key: Key, in entry: inout Board) {
        let counted = key.step != entry.overview
        if let old = entry.tiles[key], counted { bytes -= old.bytes }
        entry.tiles[key] = tile
        if counted { bytes += tile.bytes }
    }

    /// What stands in for a tile still to come: the picture of the whole artboard, then what
    /// there is of the nearest other step, drawn over it.
    private func standIns(_ entry: Board, for rect: CGRect, step s: CGFloat) -> [Tile] {
        var whole: [Tile] = []
        var best: (distance: CGFloat, tiles: [Tile])?
        for (key, tile) in entry.tiles where key.step != s && !tile.provisional && tile.rect.intersects(rect) {
            if key.step == entry.overview {
                whole.append(tile)
                continue
            }
            let d = abs(log2(key.step / s))
            if best == nil || d < best!.distance { best = (d, [tile]) } else if d == best!.distance { best!.tiles.append(tile) }
        }
        return whole + (best?.tiles ?? [])
    }

    /// Forgets the tiles that show any of `damage`, all of them for nil.
    private func forget(in entry: inout Board, where damage: CGRect?) {
        if damage?.isNull == true { return }
        for (key, tile) in entry.tiles {
            // Edges are softened over about a pixel, whatever the zoom.
            let pad = max(2, 2 / key.step)
            if let damage, !tile.rect.intersects(damage.insetBy(dx: -pad, dy: -pad)) { continue }
            entry.tiles[key] = nil
            if key.step != entry.overview { bytes -= tile.bytes }
        }
    }

    /// Lets go of the tiles least lately drawn until the rest fit the budget; those drawn this
    /// frame stay, even over it.
    private func trim() {
        var all: [(board: UUID, key: Key, used: UInt64, bytes: Int)] = []
        for (id, board) in boards {
            for (key, tile) in board.tiles where tile.used < clock && key.step != board.overview { all.append((id, key, tile.used, tile.bytes)) }
        }
        for old in all.sorted(by: { $0.used < $1.used }) {
            guard bytes > budget else { break }
            boards[old.board]?.tiles[old.key] = nil
            bytes -= old.bytes
        }
    }

    private func place(_ image: CGImage, _ rect: CGRect, _ origin: CGPoint, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: origin.x + rect.minX, y: origin.y + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// The artboard's paper, where a tile is still to come: its colour, or the colours of its
    /// gradient mixed, or a quiet grey for a picture.
    private func paper(_ board: Node, under rect: CGRect, _ origin: CGPoint, _ ctx: CGContext) {
        let r = rect.intersection(CGRect(origin: .zero, size: board.frame.size))
        guard !r.isNull else { return }
        let fill = board.fill
        var color = fill.on ? fill.color : .white
        if fill.on, let stops = fill.gradient?.stops, !stops.isEmpty {
            let n = Double(stops.count)
            color = RGBA(r: stops.reduce(0) { $0 + $1.color.r } / n, g: stops.reduce(0) { $0 + $1.color.g } / n,
                         b: stops.reduce(0) { $0 + $1.color.b } / n, a: 1)
        } else if fill.on, fill.image != nil {
            color = RGBA(r: 0.85, g: 0.85, b: 0.85, a: 1)
        }
        ctx.setFillColor(color.cgColor)
        ctx.fill(r.offsetBy(dx: origin.x, dy: origin.y))
    }
}

/// Where two versions of an artboard look different, in the artboard's own coordinates.
@MainActor
enum Damage {
    /// Null when they look the same; nil when they differ all over, such as when the artboard
    /// itself changed. Background blurs over what changed are left out: see `behind`.
    static func between(_ old: Node, _ new: Node) -> CGRect? {
        guard shell(old) == shell(new) else { return nil }
        var damage = CGRect.null
        compare(old.children, new.children, .zero, .zero, spread: 0, into: &damage)
        return damage
    }

    /// Where background blurs show what lies behind them over `damage`, and so changed with it.
    static func behind(_ damage: CGRect, among backdrops: [CGRect]) -> CGRect {
        var out = CGRect.null, reach = damage
        for _ in 0..<2 {
            for r in backdrops where r.intersects(reach) { out = out.union(r) }
            reach = reach.union(out)
        }
        return out
    }

    /// Where each background blur on an artboard reaches, in its coordinates.
    static func backdrops(of board: Node) -> [CGRect] {
        var out: [CGRect] = []
        func walk(_ nodes: [Node], _ origin: CGPoint) {
            for node in nodes where !node.hidden {
                if let blur = node.blur, blur.on, blur.background {
                    out.append(Geometry.bounds(of: node).offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -blur.radius * 3, dy: -blur.radius * 3))
                }
                if node.isGroup { walk(node.children, CGPoint(x: origin.x + node.frame.minX, y: origin.y + node.frame.minY)) }
            }
        }
        walk(board.children, .zero)
        return out
    }

    /// A layer leaving out what it holds, where it is, and what does not show: its name, its lock.
    private static func shell(_ node: Node) -> Node {
        var n = node
        n.children = []
        n.frame.origin = .zero
        // A group is as big as what it holds, and draws nothing of its own there.
        if n.isGroup { n.frame.size = .zero }
        n.name = ""
        n.locked = false
        return n
    }

    /// Layers `a` (in a parent at `ao`) against layers `b` (in one at `bo`), adding where they
    /// differ to `damage`. `spread` is how much further a parent's shadow or blur carries a change.
    private static func compare(_ a: [Node], _ b: [Node], _ ao: CGPoint, _ bo: CGPoint, spread: CGFloat, into damage: inout CGRect) {
        func add(_ node: Node, _ origin: CGPoint) {
            damage = damage.union(Renderer.reach(of: node).offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -spread, dy: -spread))
        }
        if a.count == b.count, zip(a, b).allSatisfy({ $0.id == $1.id }) {
            for (x, y) in zip(a, b) where ao != bo || x != y { changed(x, y, ao, bo, spread: spread, into: &damage) }
            return
        }
        // Some added, some taken away, or put in another order: what moved past another changed
        // where they overlap, so all that moved counts, and what was added or taken away.
        let olds = Dictionary(a.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let news = Dictionary(b.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let before = a.filter { news[$0.id] != nil }, after = b.filter { olds[$0.id] != nil }
        for (x, y) in zip(before, after) {
            if x.id != y.id {
                add(x, ao)
                add(y, bo)
            }
        }
        for y in after {
            if let x = olds[y.id], ao != bo || x != y { changed(x, y, ao, bo, spread: spread, into: &damage) }
        }
        for x in a where news[x.id] == nil { add(x, ao) }
        for y in b where olds[y.id] == nil { add(y, bo) }
    }

    private static func changed(_ x: Node, _ y: Node, _ ao: CGPoint, _ bo: CGPoint, spread: CGFloat, into damage: inout CGRect) {
        // Where it is on the artboard is all that counts: its parent may have moved around it.
        if ao != bo {
            var moved = x
            moved.frame.origin = CGPoint(x: x.frame.minX + ao.x - bo.x, y: x.frame.minY + ao.y - bo.y)
            if moved == y { return }
        }
        let xo = CGPoint(x: ao.x + x.frame.minX, y: ao.y + x.frame.minY), yo = CGPoint(x: bo.x + y.frame.minX, y: bo.y + y.frame.minY)
        // A group that only changed inside: what changed inside it, carried by its shadow or blur.
        // A mask is placed in the group's own coordinates, so a masked group counts as a whole if it moved.
        // One turned in depth shows a change inside it somewhere else, so it counts as a whole.
        if x.isGroup, y.isGroup, shell(x) == shell(y), x.mask == nil || xo == yo, Perspective(y) == nil {
            compare(x.children, y.children, xo, yo, spread: spread + effects(y), into: &damage)
            return
        }
        if ao == bo && shell(x) == shell(y) && x.frame.origin == y.frame.origin && x.children == y.children { return }
        // A path whose points moved changed only along the curves either side of them.
        if let moved = curvesMoved(x, y, ao, bo) {
            damage = damage.union(moved.insetBy(dx: -spread - effects(y), dy: -spread - effects(y)))
            return
        }
        damage = damage.union(Renderer.reach(of: x).offsetBy(dx: ao.x, dy: ao.y).insetBy(dx: -spread, dy: -spread))
        damage = damage.union(Renderer.reach(of: y).offsetBy(dx: bo.x, dy: bo.y).insetBy(dx: -spread, dy: -spread))
    }

    /// Where two versions of a path differ, when only some of its points moved: around the curves
    /// that run to and from them, old and new. Nil when more than that changed, or when a change
    /// anywhere shows everywhere: a gradient or picture spread over its box, dashes along its length.
    private static func curvesMoved(_ x: Node, _ y: Node, _ ao: CGPoint, _ bo: CGPoint) -> CGRect? {
        guard x.kind == .path, y.kind == .path, x.path != y.path, !y.borders.contains(where: { $0.dash > 0 }),
              Perspective(x) == nil, Perspective(y) == nil else { return nil }
        if x.frame.size != y.frame.size, y.fills.contains(where: { $0.gradient != nil || $0.image != nil }) || y.borders.contains(where: \.paints) { return nil }
        func outlineless(_ n: Node) -> Node {
            var n = shell(n)
            n.frame = .zero
            n.path = nil
            n.pathBox = nil
            return n
        }
        guard outlineless(x) == outlineless(y) else { return nil }
        func elements(_ n: Node, _ o: CGPoint) -> [(type: CGPathElementType, points: [CGPoint])] {
            var out: [(type: CGPathElementType, points: [CGPoint])] = []
            var t = CGAffineTransform(translationX: o.x, y: o.y)
            let placed = Renderer.placedOutline(of: n).copy(using: &t) ?? Renderer.placedOutline(of: n)
            placed.applyWithBlock { e in
                let count: Int = switch e.pointee.type {
                case .moveToPoint, .addLineToPoint: 1
                case .addQuadCurveToPoint: 2
                case .addCurveToPoint: 3
                default: 0
                }
                out.append((e.pointee.type, (0..<count).map { e.pointee.points[$0] }))
            }
            return out
        }
        let a = elements(x, ao), b = elements(y, bo)
        guard a.count == b.count, zip(a, b).allSatisfy({ $0.type == $1.type }) else { return nil }
        func same(_ p: [CGPoint], _ q: [CGPoint]) -> Bool { zip(p, q).allSatisfy { abs($0.x - $1.x) < 1e-6 && abs($0.y - $1.y) < 1e-6 } }
        var box = CGRect.null
        func add(_ p: CGPoint) { box = box.union(CGRect(origin: p, size: .zero)) }
        for k in a.indices where !same(a[k].points, b[k].points) {
            for e in [a, b] {
                e[k].points.forEach(add)
                // The curve to here starts where the one before ends; the next one starts here.
                if k > 0, let start = e[k - 1].points.last { add(start) }
                if k + 1 < e.count { e[k + 1].points.forEach(add) }
                // The first point is also where the line that closes the run comes back to.
                let run = e[...k].lastIndex { $0.type == .moveToPoint } ?? 0
                add(e[run].points.first ?? .zero)
                if let close = e[k...].firstIndex(where: { $0.type == .closeSubpath }), close > 0, let last = e[close - 1].points.last { add(last) }
            }
        }
        guard !box.isNull else { return .null }
        // A border's corners can reach out several times its width.
        let reach = (y.borders.isEmpty ? 0 : max(x.borderWidth, y.borderWidth) * 6) + 2
        return box.insetBy(dx: -reach, dy: -reach)
    }

    /// How far a layer's own shadow and blur carry what is drawn in it.
    private static func effects(_ node: Node) -> CGFloat {
        var d: CGFloat = node.shadows.lazy.map { abs($0.x) + abs($0.y) + $0.blur * 2 + abs($0.grown) }.max() ?? 0
        if let blur = node.blur, blur.on, !blur.background { d += blur.radius * 3 }
        return d
    }
}

nonisolated extension Renderer {
    /// Where a layer may paint in its own coordinates, its frame's top left at zero, leaving out
    /// its shadow and blur.
    static func ink(of node: Node) -> CGRect {
        let own = CGRect(origin: .zero, size: node.frame.size)
        switch node.kind {
        case .group:
            var r = CGRect.null
            for child in node.children where !child.hidden { r = r.union(reach(of: child)) }
            return r.isNull ? own : r
        case .text:
            // Along a curve, the frame is the box round the letters, which lean out of it a little.
            if node.isCurved {
                let size = max(node.style?.size ?? 24, node.spans?.compactMap(\.look.size).max() ?? 0)
                return own.insetBy(dx: -size / 4, dy: -size / 4)
            }
            // Words may run past the frame, and letters lean out of their boxes.
            let used = TextLayout.layout(node).usedSize
            let size = max(node.style?.size ?? 24, node.spans?.compactMap(\.look.size).max() ?? 0)
            let top = min(0, TextLayout.offset(node))
            return CGRect(x: 0, y: top, width: max(own.width, used.width), height: max(own.height, used.height + max(0, TextLayout.offset(node))) - top)
                .insetBy(dx: -size / 2, dy: -size / 2)
        default:
            let w = node.borderWidth
            return own.insetBy(dx: -w - 1, dy: -w - 1)
        }
    }

    /// Where a layer may paint in its parent's coordinates, its shadow and blur included, and
    /// turned in depth.
    static func reach(of node: Node) -> CGRect {
        if let perspective = Perspective(node) {
            return shadowed(perspective.bounds(of: reach(of: flattened(node))), by: node, spreading: false)
        }
        var r = shadowed(ink(of: node).applying(localTransform(node)), by: node)
        if let blur = node.blur, blur.on, !blur.background { r = r.insetBy(dx: -blur.radius * 3, dy: -blur.radius * 3) }
        return r
    }

    /// What a layer drawn over `r` covers with the shadows it casts under it as well: each falls
    /// as far as it is moved, spreads and is blurred. Turned in depth, a layer casts from what it
    /// shows, which a spread does not grow.
    static func shadowed(_ r: CGRect, by node: Node, spreading: Bool = true) -> CGRect {
        var all = r
        for s in node.outerShadows {
            let grow = s.blur * 2 + (spreading && spreads(node, s) ? max(s.grown, 0) : 0)
            all = all.union(r.offsetBy(dx: s.x, dy: s.y).insetBy(dx: -grow, dy: -grow))
        }
        return all
    }

    /// Part of an artboard, `rect` on the canvas, drawn into a picture `scale` pixels to the point;
    /// only the layers that reach into it are drawn.
    static func tile(of board: Node, rect: CGRect, scale: CGFloat, options: Options) -> CGImage? {
        let w = Int((rect.width * scale).rounded()), h = Int((rect.height * scale).rounded())
        guard w > 0, h > 0, let ctx = bitmap(CGSize(width: w, height: h)) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        var part = options
        part.visible = rect
        withFlippedContext(ctx) { drawArtboard(board, in: ctx, options: part) }
        return ctx.makeImage()
    }

    /// Whether any of a layer can be seen, counting how far its shadow and blur reach.
    static func inSight(_ node: Node, _ options: Options) -> Bool {
        guard let visible = options.visible, let board = options.board else { return true }
        var reach: CGFloat = 64 + node.borderWidth
        reach += node.outerShadows.lazy.map { abs($0.x) + abs($0.y) + $0.blur * 2 + max($0.grown, 0) }.max() ?? 0
        if let blur = node.blur, blur.on { reach += blur.radius * 3 }
        let r = Geometry.bounds(of: node).offsetBy(dx: board.frame.minX + options.offset.x, dy: board.frame.minY + options.offset.y)
        return r.insetBy(dx: -reach, dy: -reach).intersects(visible)
    }
}
