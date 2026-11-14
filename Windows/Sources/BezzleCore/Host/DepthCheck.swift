import Foundation

// For trying what Bezzle for Windows does with depth without its window (bezzle-render <fonts>
// depth <out folder>): several layers turned as one body by the 3D card, from a side on the
// canvas and by the AI server; groups that keep their layers' depth, told by the card's switch
// and the AI server, picked, drawn and in a film; and an artboard looked at from the side, kept
// by the host beside the design, drawn by the canvas alone, and never part of the design. The
// scenes and the numbers are those of the Mac's DepthBodyTests, DepthKeepTests and
// DepthLookTests, worked out by hand there; what is asked here is the Windows host, as the
// window asks it. Each line says what held or did not.

extension WindowsCore {
    /// Tries all of it, with designs of its own made in `out`. What held and what did not, a
    /// line each, and how many did not.
    public static func depthCheck(into out: URL) async -> (lines: [String], failed: Int) {
        let checks = DepthChecks(out)
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try checks.bodies()
            try checks.fromASide()
            try checks.groups()
            try await checks.looking()
            try await checks.assistant()
        } catch {
            checks.expect(false, "the checks ran to their end", "\(error)")
        }
        return (checks.said + ["\(checks.held) held, \(checks.failed) did not"], checks.failed)
    }
}

@MainActor private final class DepthChecks {
    /// Where the designs tried are made.
    let folder: URL
    var said: [String] = []
    var held = 0, failed = 0
    /// A 400 by 300 artboard, seen from 800 points in front of its middle.
    let size = CGSize(width: 400, height: 300)
    let red = RGBA(r: 1, g: 0, b: 0), blue = RGBA(r: 0, g: 0, b: 1)

    init(_ folder: URL) { self.folder = folder }

    func expect(_ ok: Bool, _ what: String, _ found: @autoclosure () -> String = "") {
        if ok {
            held += 1
            said.append("  ok      \(what)")
        } else {
            failed += 1
            let more = found()
            said.append("  FAILED  \(what)" + (more.isEmpty ? "" : ": \(more)"))
        }
    }

    // MARK: Scenes

    func card(_ name: String, _ frame: CGRect, z: CGFloat = 0, turn: (x: Double, y: Double) = (0, 0), color: RGBA = .white) -> Node {
        var n = Node(kind: .rectangle, name: name, frame: frame)
        n.fill.color = color
        if z != 0 || turn.x != 0 || turn.y != 0 { n.transform3D = Transform3D(x: turn.x, y: turn.y, z: z) }
        return n
    }

    func group(_ name: String, _ frame: CGRect, _ children: [Node], z: CGFloat = 0, turn: (x: Double, y: Double) = (0, 0), keeps: Bool = true) -> Node {
        var g = Node(kind: .group, name: name, frame: frame)
        g.children = children
        if z != 0 || turn.x != 0 || turn.y != 0 { g.transform3D = Transform3D(x: turn.x, y: turn.y, z: z) }
        if keeps { g.keepsDepth = true }
        return g
    }

    func board(_ children: [Node], name: String = "Stage", at origin: CGPoint = .zero, clips: Bool = true) -> Node {
        var b = Node(kind: .artboard, name: name, frame: CGRect(origin: origin, size: size))
        b.fill.color = .black
        b.clips = clips
        b.children = children
        return b
    }

    /// A card with a button raised 20 points off it, to the right of its middle.
    var cardAndButton: [Node] {
        [card("Card", CGRect(x: 100, y: 100, width: 200, height: 100)),
         card("Button", CGRect(x: 240, y: 140, width: 40, height: 20), z: 20, color: red)]
    }

    /// A group swung and lifted, holding a card lying in it, one standing off it tipped, and a
    /// group tipped again that holds a card of its own off its plane.
    func turned(keeps: Bool) -> Node {
        let deep = group("Inner", CGRect(x: 10, y: 20, width: 100, height: 60),
                         [card("Deep", CGRect(x: 5, y: 5, width: 30, height: 20), z: 15)], z: 10, turn: (25, 0), keeps: keeps)
        return board([group("Group", CGRect(x: 100, y: 50, width: 200, height: 100), [
            card("Lying", CGRect(x: 100, y: 30, width: 80, height: 50), color: red),
            card("Standing", CGRect(x: 20, y: 10, width: 60, height: 40), z: 50, turn: (20, 0), color: blue),
            deep,
        ], z: 30, turn: (0, 40), keeps: keeps)])
    }

    /// A red card 40 off the page, listed under a group that lies in the page and holds a white
    /// card in it and a blue one 80 off it, all over one another.
    func crossing(keeps: Bool) -> Node {
        board([
            card("Beside", CGRect(x: 150, y: 100, width: 100, height: 100), z: 40, color: red),
            group("Over", CGRect(x: 100, y: 50, width: 200, height: 200), [
                card("Low", CGRect(x: 60, y: 60, width: 80, height: 80)),
                card("High", CGRect(x: 70, y: 70, width: 40, height: 40), z: 80, color: blue),
            ], keeps: keeps),
        ], name: "Crossing", at: CGPoint(x: 0, y: 400))
    }

    /// Writes a design of these artboards into the out folder as a design is written, and opens
    /// it beside whatever is open, as a tab does.
    func open(_ name: String, _ boards: [Node]) throws -> (slot: WindowsCore.Slot, package: URL) {
        let package = folder.appendingPathComponent("\(name).bezzle", isDirectory: true)
        try? FileManager.default.removeItem(at: package)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("images", isDirectory: true), withIntermediateDirectories: true)
        var doc = BezzleDocument()
        doc.nodes = boards
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(doc).write(to: package.appendingPathComponent("document.json"))
        return (try WindowsCore.openSlot(package), package)
    }

    var doc: BezzleDocument { WindowsCore.design ?? BezzleDocument() }

    func node(_ name: String) -> Node {
        doc.allNodes.first { $0.name == name } ?? Node(kind: .rectangle, name: "nothing called \(name)", frame: .zero)
    }

    // MARK: Worked out by hand

    func far(_ a: ScenePoint, _ b: ScenePoint) -> Double {
        let d = a - b
        return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
    }

    /// How far the furthest of these points is from where a body turned by `spin` about `pivot`
    /// takes it: nothing, for one body.
    func off(_ before: [ScenePoint], _ after: [ScenePoint], _ spin: Spin, _ pivot: ScenePoint) -> Double {
        guard before.count == after.count, !before.isEmpty else { return .infinity }
        return zip(before, after).map { far(pivot + spin($0 - pivot), $1) }.max() ?? .infinity
    }

    func corners(of doc: BezzleDocument) -> [ScenePoint] { doc.nodes[0].children.flatMap { DepthBody.corners(of: $0) } }

    /// Where a place in the artboard's scene shows, seen from its eye.
    func seen(_ p: ScenePoint) -> CGPoint {
        let k = 800 / (800 - p.z)
        return CGPoint(x: 200 + (p.x - 200) * k, y: 150 + (p.y - 150) * k)
    }

    /// Where a point of a layer's parent stands in the scene of what holds that parent, the
    /// layer turned about its middle and lifted: one step for each layer.
    func stood(_ p: ScenePoint, in layer: Node) -> ScenePoint {
        let t = layer.transform3D ?? Transform3D()
        let middle = ScenePoint(x: layer.frame.midX, y: layer.frame.midY)
        return Spin(t)(p - middle) + middle + ScenePoint(z: t.z)
    }

    /// The same for a point given inside a group: in what holds the group.
    func out(_ p: ScenePoint, of group: Node) -> ScenePoint {
        stood(p + ScenePoint(x: group.frame.minX, y: group.frame.minY), in: group)
    }

    func corners(_ n: Node) -> [CGPoint] { Geometry.corners(of: n.frame, rotation: n.rotation) }
    func flat(_ p: CGPoint) -> ScenePoint { ScenePoint(x: p.x, y: p.y) }
    func middle(_ n: Node) -> CGPoint { CGPoint(x: n.frame.midX, y: n.frame.midY) }
    func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: Double = 1e-6) -> Bool { hypot(a.x - b.x, a.y - b.y) < tolerance }
    func near(_ a: CGRect, _ b: CGRect, _ tolerance: Double = 1e-9) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    /// Where a point 40 off the page shows across, seen from an eye standing at `eye` across, 800 above.
    func across(_ x: Double, from eye: Double, height: Double = 40) -> Double { eye + (x - eye) * 800 / (800 - height) }

    // MARK: Pictures

    typealias Dot = (r: Int, g: Int, b: Int)

    /// The colour at a point of a picture, premultiplied RGBA with rows top first.
    func pixel(_ pixels: [UInt8], _ width: Int, _ x: Double, _ y: Double) -> Dot {
        let height = width > 0 ? pixels.count / 4 / width : 0
        let px = Int(x.rounded()), py = Int(y.rounded())
        guard px >= 0, py >= 0, px < width, py < height else { return (-1, -1, -1) }
        let i = (py * width + px) * 4
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
    }

    func isRed(_ c: Dot) -> Bool { c.r > 242 && c.g < 13 && c.b < 13 }
    func isBlue(_ c: Dot) -> Bool { c.b > 242 && c.r < 13 && c.g < 13 }
    func isWhite(_ c: Dot) -> Bool { c.r > 242 && c.g > 242 && c.b > 242 }
    func isBlack(_ c: Dot) -> Bool { c.r >= 0 && c.r < 13 && c.g < 13 && c.b < 13 }

    // MARK: Several layers as one body

    func bodies() throws {
        said.append("Several layers turned as one body, from the 3D card")
        let (slot, _) = try open("Body", [board(cardAndButton)])
        defer { WindowsCore.closeSlot(slot) }
        let ids = [node("Card").id, node("Button").id]
        let before = doc
        let pivot = ScenePoint(x: 200, y: 150, z: 10)
        let s = sin(40 * Double.pi / 180), k = cos(40 * Double.pi / 180)

        // Read by its lead, the card.
        let read = WindowsCore.looks(ids)?.depth
        expect(read != nil && read?.xs == 0 && read?.ys == 0 && read?.zs == 0 && read?.summary == "0°, 0°",
               "the card of a card and the button raised off it says how the card, their lead, is turned", "\(String(describing: read))")
        expect(WindowsCore.depthLead(of: [node("Card"), node("Button")])?.name == "Card" && WindowsCore.depthLead(of: [node("Card")]) == nil,
               "the two have a lead, the larger face, and one layer has none")
        expect(read?.groups == false, "neither is a group: no switch for keeping depth")

        // Y turns them as one body about the middle they share.
        WindowsCore.change(ids, .depthY(40))
        let c = node("Card"), b = node("Button")
        expect(c.transform3D?.x == 0 && c.transform3D?.y == 40 && b.transform3D?.x == 0 && b.transform3D?.y == 40,
               "Y 40 turns both to face one way", "\(String(describing: c.transform3D)) \(String(describing: b.transform3D))")
        expect(abs(c.frame.midX - (200 - 10 * s)) < 1e-9 && abs(c.frame.midY - 150) < 1e-9 && abs((c.transform3D?.z ?? 0) - (10 - 10 * k)) < 1e-9,
               "the card, 10 under the middle they share, goes a little left", "\(c.frame) z \(c.transform3D?.z ?? 0)")
        expect(abs(b.frame.midX - (200 + 60 * k + 10 * s)) < 1e-9 && abs(b.frame.midY - 150) < 1e-9 && abs((b.transform3D?.z ?? 0) - (10 - 60 * s + 10 * k)) < 1e-9,
               "the button's side of the body has swung away", "\(b.frame) z \(b.transform3D?.z ?? 0)")
        expect(c.frame.size == CGSize(width: 200, height: 100) && b.frame.size == CGSize(width: 40, height: 20), "neither changed its size")
        expect(off(corners(of: before), corners(of: doc), .swing(40), pivot) < 1e-6, "every corner of both went round that middle as one thing",
               "\(off(corners(of: before), corners(of: doc), .swing(40), pivot))")
        let again = WindowsCore.looks(ids)?.depth
        expect(again?.ys == 40 && again?.xs == 0 && again?.summary.hasPrefix("0°, 40°") == true, "the card reads the turn back", "\(String(describing: again))")

        // The button over its card where the body has it: drawn so.
        if let picture = WindowsCore.render(board: 0, scale: 1) {
            let at = seen(ScenePoint(x: b.frame.midX, y: b.frame.midY, z: b.transform3D?.z ?? 0))
            expect(isRed(pixel(picture.pixels, picture.width, at.x, at.y)) && at.x < 255,
                   "the button is drawn over the card at its own middle, where the body has taken it", "\(at) \(pixel(picture.pixels, picture.width, at.x, at.y))")
            expect(isWhite(pixel(picture.pixels, picture.width, at.x - 24, at.y)) && !isRed(pixel(picture.pixels, picture.width, 296, 150)),
                   "the card under it, and nothing red where the button lay", "\(pixel(picture.pixels, picture.width, at.x - 24, at.y)) \(pixel(picture.pixels, picture.width, 296, 150))")
        } else {
            expect(false, "the turned body is drawn")
        }

        // One step of the history.
        let swung = doc
        expect(WindowsCore.undo() && doc == before, "one Undo lays both back")
        expect(!WindowsCore.undo(), "it was one step")
        expect(WindowsCore.redo() && doc == swung, "Redo turns them again")

        // Laid flat, to the point.
        WindowsCore.change(ids, .layFlat)
        let exactly = node("Card").frame == CGRect(x: 100, y: 100, width: 200, height: 100) && node("Button").frame == CGRect(x: 240, y: 140, width: 40, height: 20)
        expect(near(node("Card").frame, CGRect(x: 100, y: 100, width: 200, height: 100)) && near(node("Button").frame, CGRect(x: 240, y: 140, width: 40, height: 20)),
               "Lay Flat lays both where they lay" + (exactly ? ", to the point" : ", within a billionth of a point"), "\(node("Card").frame) \(node("Button").frame)")
        expect(node("Card").transform3D == Transform3D() && node("Button").transform3D == Transform3D(z: 20), "the card in the page and the button 20 off it, as before",
               "\(String(describing: node("Card").transform3D)) \(String(describing: node("Button").transform3D))")

        // Z lifts the whole body.
        WindowsCore.change(ids, .depthY(30))
        let low = node("Card").transform3D?.z ?? 0, high = node("Button").transform3D?.z ?? 0
        WindowsCore.change(ids, .depthZ(50))
        expect(node("Card").transform3D?.z == 50 && abs((node("Button").transform3D?.z ?? 0) - (high + 50 - low)) < 1e-6,
               "Z 50 lifts the whole body by as much as its lead goes", "\(node("Card").transform3D?.z ?? 0) \(node("Button").transform3D?.z ?? 0)")

        // A drag of the aim pad: from where the body stood when it began, and one step.
        let stood = doc
        WindowsCore.beginGesture()
        for (x, y) in [(5.0, 10.0), (-12, -20), (20, 45), (10, 30)] { WindowsCore.change(ids, .aim(x, y)) }
        WindowsCore.endGesture()
        var once = stood
        once.turnInDepth(ids) { _, now in
            var t = now
            t.x = 10
            t.y = 30
            return t
        }
        expect(doc.nodes[0].children == once.nodes[0].children, "a drag of the aim pad turns the body once, from where it stood when the drag began")
        expect(WindowsCore.undo() && doc == stood, "and is one step")
        WindowsCore.redo()

        // The dial tips it further.
        let aimed = doc
        WindowsCore.change(ids, .tip(55))
        var tipped = aimed
        tipped.turnInDepth(ids) { _, now in now.tipped(55) }
        expect(doc.nodes[0].children == tipped.nodes[0].children && doc != aimed, "the dial tips the body as the model tips it")

        // Pointed at, a turn shows on the whole body, and is gone again.
        let shown = doc
        WindowsCore.preview(ids, .depthY(-60))
        expect(node("Card").transform3D?.y == -60 && node("Button").transform3D?.y == -60 && node("Button").frame != shown.allNodes.first { $0.name == "Button" }?.frame,
               "a turn shown ahead shows on the whole body")
        expect(WindowsCore.endPreview() && doc == shown, "and is gone when it is taken away")

        // Out of 3D while turned.
        WindowsCore.change(ids, .removeDepth)
        expect(node("Card").transform3D == nil && node("Button").transform3D == nil, "taken out of 3D, neither has anything of depth left")
        expect(near(node("Card").frame, CGRect(x: 100, y: 100, width: 200, height: 100)) && near(node("Button").frame, CGRect(x: 240, y: 140, width: 40, height: 20)),
               "and both lie as they lay before they were turned", "\(node("Card").frame) \(node("Button").frame)")

        // Added from flat: held up a little, as one body.
        let lying = doc
        WindowsCore.change(ids, .addDepth)
        var heldUp = lying
        heldUp.turnInDepth(ids) { _, _ in Presets.heldUp }
        expect(node("Card").transform3D?.x == Presets.heldUp.x && node("Button").transform3D?.y == Presets.heldUp.y && doc.nodes[0].children == heldUp.nodes[0].children,
               "3D added to both holds them up a little as one body")

        // One layer alone turns about its own middle, as it always did.
        let alone = [node("Button").id]
        let was = node("Card")
        WindowsCore.change(alone, .depthX(25))
        expect(node("Button").transform3D?.x == 25 && node("Card") == was, "one layer alone is turned about its own middle")
    }

    func fromASide() throws {
        said.append("Several layers turned from a side on the canvas")
        let (slot, _) = try open("Side", [board(cardAndButton)])
        defer { WindowsCore.closeSlot(slot) }
        let ids = [node("Card").id, node("Button").id]
        let before = doc
        // Just outside the middle of the right side of the two, 12 points off it.
        let hit = WindowsCore.hit(at: CGPoint(x: 312, y: 150), selection: ids, zoom: 1, pan: .zero, selecting: true)
        expect(hit == .turnInDepth, "just outside the middle of a side of what is picked, the pointer turns it in depth", "\(String(describing: hit))")
        let hand = WindowsCore.Depth()
        hand.selection = ids
        hand.startTurn(at: CGPoint(x: 312, y: 150))
        hand.drag(to: CGPoint(x: 330, y: 150), shift: false, option: false)
        hand.drag(to: CGPoint(x: 352, y: 150), shift: false, option: false)
        hand.up(at: CGPoint(x: 352, y: 150), adding: false)
        let t = node("Card").transform3D ?? Transform3D()
        expect(t.y > 15 && t.x == 0, "dragged 40 points outwards, the card has swung", "\(t)")
        expect(node("Button").transform3D?.x == 0 && node("Button").transform3D?.y == t.y && node("Button").frame.origin != CGPoint(x: 240, y: 140),
               "and its button with it, facing the same way", "\(String(describing: node("Button").transform3D)) \(node("Button").frame)")
        var expected = before
        expected.turnInDepth(ids) { _, _ in Transform3D(y: t.y) }
        expect(doc.nodes[0].children == expected.nodes[0].children, "as the model turns a body to there, from where it stood when the drag began")
        expect(!hand.dragging && WindowsCore.undo() && doc == before && !WindowsCore.undo(), "the drag is one step")
    }

    // MARK: Groups that keep their layers' depth

    func groups() throws {
        said.append("Groups that keep their layers' depth")
        let (slot, package) = try open("Keeps", [turned(keeps: true), crossing(keeps: false)])
        defer { WindowsCore.closeSlot(slot) }
        let g = node("Group"), inner = node("Inner"), standing = node("Standing"), lying = node("Lying"), deep = node("Deep")

        // The card's switch.
        let read = WindowsCore.looks([g.id])?.depth
        expect(read?.groups == true && read?.keepDepth == true, "the 3D card of a group that keeps depth has the switch, on", "\(String(describing: read))")
        expect(WindowsCore.looks([standing.id])?.depth?.groups == false, "a rectangle has no such switch")

        // Picked where its layers stand.
        let standingMiddle = seen(out(stood(flat(middle(standing)), in: standing), of: g))
        let deepMiddle = seen(out(out(stood(flat(middle(deep)), in: deep), of: inner), of: g))
        let lyingMiddle = seen(out(flat(middle(lying)), of: g))
        expect(WindowsCore.hit(standingMiddle, zoom: 1) == g.id, "a click on a layer standing off the group takes the group", "\(standingMiddle)")
        expect(WindowsCore.pick(standingMiddle, selection: [lying.id], zoom: 1) == standing.id, "with a layer of the group picked, it takes the layer")
        expect(WindowsCore.pick(standingMiddle, inGroup: g.id, zoom: 1) == standing.id, "a double click on the group goes in to the layer there")
        expect(WindowsCore.hit(deepMiddle, zoom: 1) == g.id && WindowsCore.pick(deepMiddle, selection: [lying.id], zoom: 1) == inner.id,
               "a group keeping depth inside it passes the scene on", "\(deepMiddle)")
        let empty = seen(out(ScenePoint(x: 195, y: 95), of: g))
        expect(WindowsCore.hit(empty, zoom: 1) == nil, "where the group as a card would be and no layer shows, there is nothing to take")
        expect(WindowsCore.marquee(CGRect(x: standingMiddle.x - 1, y: standingMiddle.y - 1, width: 2, height: 2), onBoard: 0, zoom: 1) == [g.id],
               "a box dragged over the standing layer takes the group")

        // As big as its layers show.
        var all = corners(standing).map { seen(out(stood(flat($0), in: standing), of: g)) }
        all += corners(lying).map { seen(out(flat($0), of: g)) }
        all += corners(deep).map { seen(out(out(stood(flat($0), in: deep), of: inner), of: g)) }
        let xs = all.map(\.x), ys = all.map(\.y)
        let box = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
        let bounds = WindowsCore.bounds(of: [g.id]) ?? .zero
        expect(near(bounds, box, 1e-6), "the group is as big on the canvas as its layers show, not as its card would", "\(bounds) against \(box)")

        // Drawn there.
        if let picture = WindowsCore.render(board: 0, scale: 1) {
            let at = { (p: CGPoint) in self.pixel(picture.pixels, picture.width, p.x, p.y) }
            expect(isBlue(at(standingMiddle)) && isRed(at(lyingMiddle)) && isWhite(at(deepMiddle)),
                   "each layer is drawn where it stands: blue, red and white at their middles", "\(at(standingMiddle)) \(at(lyingMiddle)) \(at(deepMiddle))")
        } else {
            expect(false, "the group is drawn")
        }

        // In a film at rest, each layer where the design shows it.
        let stage = doc.nodes[0]
        expect(stage.filmPieces().map(\.layers) == [[], [lying.id], [standing.id], [deep.id]], "a film takes the group apart into pieces standing in the scene")
        if let frame = WindowsCore.FilmMovie.frame(of: stage, at: 0, size: size) {
            let at = { (p: CGPoint) in self.pixel(frame, 400, p.x, p.y) }
            expect(isBlue(at(standingMiddle)) && isRed(at(lyingMiddle)) && isWhite(at(deepMiddle)),
                   "and its first frame shows each where the design does", "\(at(standingMiddle)) \(at(lyingMiddle)) \(at(deepMiddle))")
        } else {
            expect(false, "a frame of its film is drawn")
        }

        // The switch off: one card again, and no key left in the file.
        WindowsCore.change([g.id], .keepDepth(false))
        expect(node("Group").keepsDepth == nil && node("Inner").keepsDepth == true, "the switch off makes the group one card again, the group in it as it was")
        expect(WindowsCore.looks([g.id])?.depth?.keepDepth == false && WindowsCore.looks([g.id])?.depth?.groups == true, "and the card shows the switch off")
        let asOneCard = WindowsCore.bounds(of: [g.id]) ?? .zero
        expect(!near(asOneCard, box, 1), "as a card it is as big as its card shows", "\(asOneCard)")
        try WindowsCore.save()
        var written = String(decoding: try Data(contentsOf: package.appendingPathComponent("document.json")), as: UTF8.self)
        expect(written.components(separatedBy: "\"keepsDepth\":true").count == 2, "saved, only the inner group has the key", "\(written.components(separatedBy: "keepsDepth").count - 1) keys")
        expect(WindowsCore.undo() && node("Group").keepsDepth == true, "one Undo and it keeps depth again")
        try WindowsCore.save()
        written = String(decoding: try Data(contentsOf: package.appendingPathComponent("document.json")), as: UTF8.self)
        expect(written.components(separatedBy: "\"keepsDepth\":true").count == 3 && !written.contains("\"keepsDepth\":false"), "saved so, both groups have it")

        // Only a group can be told.
        let leaf = doc
        WindowsCore.change([standing.id], .keepDepth(true))
        expect(doc == leaf && node("Standing").keepsDepth == nil, "a rectangle told to keep depth stays as it is")

        // Told from the card, the layers of a group stand among what lies beside it.
        let over = node("Over"), beside = node("Beside")
        let onCanvas = { (x: Double, y: Double) in CGPoint(x: x, y: y + 400) }
        expect(WindowsCore.hit(onCanvas(190, 140), zoom: 1) == beside.id, "as one card, a group lying in the page is under the card held over it")
        let asCard = WindowsCore.render(board: 1, scale: 1)
        expect(asCard.map { isRed(pixel($0.pixels, $0.width, 190, 140)) } == true, "and is drawn under it")
        WindowsCore.change([over.id], .keepDepth(true))
        expect(node("Over").keepsDepth == true && WindowsCore.hit(onCanvas(190, 140), zoom: 1) == over.id && WindowsCore.hit(onCanvas(230, 180), zoom: 1) == beside.id,
               "the switch on, its high layer stands over that card and its low one under it: a click meets them so")
        let opened = WindowsCore.render(board: 1, scale: 1)
        expect(opened.map { isBlue(pixel($0.pixels, $0.width, 190, 140)) && isRed(pixel($0.pixels, $0.width, 230, 180)) } == true, "and they are drawn so",
               opened.map { "\(pixel($0.pixels, $0.width, 190, 140)) \(pixel($0.pixels, $0.width, 230, 180))" } ?? "not drawn")
        expect(WindowsCore.undo() && node("Over").keepsDepth == nil && WindowsCore.hit(onCanvas(190, 140), zoom: 1) == beside.id, "one Undo and it is a card again")
    }

    // MARK: Looking from the side

    func looking() async throws {
        said.append("An artboard looked at from the side")
        let scene = [card("Lying", CGRect(x: 20, y: 20, width: 100, height: 60)),
                     card("Lifted", CGRect(x: 180, y: 130, width: 40, height: 40), z: 40, color: red),
                     card("Leaning", CGRect(x: 300, y: 200, width: 60, height: 40), turn: (0, 40))]
        // An artboard that shows what runs past its edges, with a card held up near its right edge.
        let open = board([card("Edge", CGRect(x: 340, y: 130, width: 40, height: 40), z: 40, color: red)], name: "Open", at: CGPoint(x: 500, y: 0), clips: false)
        let (slot, package) = try self.open("Look", [board(scene), open])
        defer { WindowsCore.closeSlot(slot) }
        let stage = doc.nodes[0], wide = doc.nodes[1], lifted = node("Lifted"), lying = node("Lying"), leaning = node("Leaning")
        let view = CGSize(width: 1000, height: 700)
        let hand = WindowsCore.LookHand()

        // From the front.
        let front = WindowsCore.render(board: 0, scale: 1)
        expect(front.map { isRed(pixel($0.pixels, $0.width, 190, 150)) && isBlack(pixel($0.pixels, $0.width, 242, 150)) } == true,
               "from the front the lifted card is drawn over where it lies")
        let frontBoards = WindowsCore.boards()
        expect(hand.marks(selection: [], size: view).posts.isEmpty && hand.marks(selection: [], size: view).boards.isEmpty && !WindowsCore.lookingFromTheSide,
               "from the front there are no posts and no word")

        // The look is the host's, handed to the design.
        expect(WindowsCore.look(at: stage.id, across: -45, down: 0) && WindowsCore.lookingFromTheSide, "an artboard is looked at from 45° to the left")
        expect(WindowsCore.look(of: stage.id)?.across == -45 && WindowsCore.look(of: stage.id)?.down == 0 && doc.looks?[stage.id] == DepthLook(across: -45),
               "and the design is handed the look", "\(String(describing: doc.looks))")
        expect(!WindowsCore.look(at: stage.id, across: -45, down: 0), "looked at so again, nothing changes")
        expect(!WindowsCore.look(at: lifted.id, across: -45, down: 0) && WindowsCore.look(of: lifted.id) == nil, "only an artboard is looked at")
        WindowsCore.look(at: stage.id, across: 90, down: 0)
        expect(WindowsCore.look(of: stage.id)?.across == 60, "no further round than sixty degrees", "\(String(describing: WindowsCore.look(of: stage.id)))")
        WindowsCore.look(at: stage.id, across: -45, down: 0)

        // Everything on the canvas is true to it.
        expect(WindowsCore.hit(CGPoint(x: 242, y: 150), zoom: 1) == lifted.id && WindowsCore.hit(CGPoint(x: 190, y: 150), zoom: 1) == nil,
               "a click takes the lifted card where it shows, not where it lies")
        expect(WindowsCore.marquee(CGRect(x: 230, y: 140, width: 20, height: 20), onBoard: 0, zoom: 1) == [lifted.id]
               && WindowsCore.marquee(CGRect(x: 180, y: 140, width: 20, height: 20), onBoard: 0, zoom: 1) == [], "a box dragged takes it there too")
        let box = WindowsCore.bounds(of: [lifted.id]) ?? .zero
        expect(abs(box.minX - across(180, from: -600)) < 1e-6 && abs(box.maxX - across(220, from: -600)) < 1e-6 && abs(box.midX - 242.105) < 0.001,
               "its box on the canvas is where it shows, a little more than 40 to the right", "\(box)")
        expect(WindowsCore.bounds(of: [lying.id]) == lying.frame, "what lies in the page stays where it is")

        // Drawn by the canvas from the side, and by nothing else.
        let side = WindowsCore.renderShown(board: 0, scale: 1)
        expect(side.map { $0.covers == stage.frame && $0.width == 400 && $0.height == 300 } == true, "the canvas's picture of an artboard that clips covers its frame")
        expect(side.map { isRed(pixel($0.pixels, $0.width, 242, 150)) && isBlack(pixel($0.pixels, $0.width, 190, 150)) && isWhite(pixel($0.pixels, $0.width, 70, 50)) } == true,
               "the canvas draws the lifted card where the moved eye sees it, and what lies in the page where it lay",
               side.map { "\(pixel($0.pixels, $0.width, 242, 150)) \(pixel($0.pixels, $0.width, 190, 150)) \(pixel($0.pixels, $0.width, 70, 50))" } ?? "not drawn")
        let still = WindowsCore.render(board: 0, scale: 1)
        expect(still != nil && still?.pixels == front?.pixels, "a picture made for anything else is from the front, to the last pixel")

        // Posts and the word.
        var marks = hand.marks(selection: [], size: view)
        let top = CGPoint(x: across(180, from: -600), y: 150 + (130 - 150) * 800 / 760.0)
        expect(marks.posts.count == 8 && marks.posts.first?.foot == CGPoint(x: 180, y: 130) && marks.posts.first.map { near($0.top, top) } == true,
               "a post stands under each corner of what is off the page, from where it would lie to where it shows", "\(marks.posts.count) posts, the first \(String(describing: marks.posts.first))")
        expect(marks.boards.count == 1 && marks.boards.first?.id == stage.id && marks.boards.first?.frame == stage.frame, "the word belongs to the artboard looked at")
        expect(hand.marks(selection: [leaning.id], size: view).posts.count == 4 && hand.marks(selection: [lying.id], size: view).posts.count == 8,
               "with one of them picked only its own posts stand, with something in the page picked all")
        hand.zoom = 2
        hand.pan = CGPoint(x: 10, y: 20)
        marks = hand.marks(selection: [], size: view)
        expect(marks.posts.first?.foot == CGPoint(x: 370, y: 280) && marks.boards.first?.frame == CGRect(x: 10, y: 20, width: 800, height: 600),
               "nearer and moved, they are where the canvas shows them", "\(String(describing: marks.posts.first)) \(String(describing: marks.boards.first))")
        hand.zoom = 1
        hand.pan = .zero
        let inView = CGRect(origin: .zero, size: view)
        expect(WindowsCore.LookHand.wordRect(by: CGRect(x: 100, y: 100, width: 400, height: 300), words: 100, in: inView) == CGRect(x: 380, y: 75, width: 120, height: 20)
               && WindowsCore.LookHand.wordRect(by: stage.frame, words: 100, in: inView) == CGRect(x: 280, y: 8, width: 120, height: 20),
               "the word stands by the artboard's top right corner, and stays in sight when that is not",
               "\(WindowsCore.LookHand.wordRect(by: CGRect(x: 100, y: 100, width: 400, height: 300), words: 100, in: inView)) \(WindowsCore.LookHand.wordRect(by: stage.frame, words: 100, in: inView))")

        // Never a step, and editing stays true.
        WindowsCore.move([lying.id], dx: 10, dy: 0)
        expect(doc.looks?[stage.id] == DepthLook(across: -45) && node("Lying").frame.minX == 30, "a change leaves the artboard looked at so")
        expect(WindowsCore.undo() && doc.looks?[stage.id] == DepthLook(across: -45) && node("Lying").frame.minX == 20, "and so does Undo")
        expect(!WindowsCore.undo(), "looking was never a step of the history")
        expect(WindowsCore.redo() && doc.looks?[stage.id] == DepthLook(across: -45) && WindowsCore.undo(), "nor does Redo forget it")
        WindowsCore.preview([lifted.id], .depthZ(80))
        expect(doc.looks?[stage.id] == DepthLook(across: -45) && node("Lifted").transform3D?.z == 80, "a change shown ahead is looked at so too")
        expect(WindowsCore.endPreview() && doc.looks?[stage.id] == DepthLook(across: -45) && node("Lifted").transform3D?.z == 40, "and the design it gives way to")

        // Never saved, never exported.
        try WindowsCore.save()
        let written = String(decoding: try Data(contentsOf: package.appendingPathComponent("document.json")), as: UTF8.self)
        expect(!written.contains("looks") && !written.contains("across"), "saved, the file has nothing of the look")
        let fromSide = folder.appendingPathComponent("exported-side", isDirectory: true), fromFront = folder.appendingPathComponent("exported-front", isDirectory: true)
        for made in [fromSide, fromFront] {
            try? FileManager.default.removeItem(at: made)
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        }
        let aside = await WindowsCore.export("all", format: "png", scale: 1, quality: 0.9, selection: [], to: fromSide, replacing: true) { _ in }

        // An artboard that does not clip is drawn as far as what stands off it reaches from there.
        WindowsCore.look(at: wide.id, across: -45, down: 0)
        let boards = WindowsCore.boards()
        let reach = boards.count == 2 ? boards[1].drawn : .zero
        let was = frontBoards.count == 2 ? frontBoards[1].drawn : .zero
        expect(boards.count == 2 && boards[0].drawn == stage.frame && reach.maxX > was.maxX + 30 && reach.maxX >= 500 + across(380, from: -600) && reach.maxX < 500 + across(380, from: -600) + 12,
               "an artboard that does not clip is drawn as far as what stands off it reaches from the side", "\(reach), from the front \(was)")
        let past = WindowsCore.renderShown(board: 1, scale: 1)
        let edge = CGPoint(x: 500 + across(360, from: -600), y: 150)
        expect(edge.x > 905 && past.map { $0.covers == reach && $0.width == Int(reach.width) && isRed(pixel($0.pixels, $0.width, edge.x - $0.covers.minX, edge.y - $0.covers.minY)) } == true,
               "and the card shows there, past the artboard's right edge",
               past.map { "covers \($0.covers), \($0.width)×\($0.height), \(pixel($0.pixels, $0.width, edge.x - $0.covers.minX, edge.y - $0.covers.minY)) at \(edge)" } ?? "not drawn")

        // The gesture: Alt dragged beside the layers.
        WindowsCore.lookFromTheFront()
        expect(hand.down(at: CGPoint(x: 300, y: 260)) && hand.board == stage.id && hand.dragging, "Alt pressed beside the layers takes the artboard under the pointer")
        expect(!hand.drag(to: CGPoint(x: 302, y: 260), steps: false) && !WindowsCore.lookingFromTheSide, "nothing turns before the pointer has gone three points")
        expect(hand.drag(to: CGPoint(x: 400, y: 260), steps: false) && WindowsCore.look(of: stage.id)?.across == -35 && WindowsCore.look(of: stage.id)?.down == 0,
               "dragged 100 points to the right, the eye goes 35° to the left: what is held up goes with the pointer", "\(String(describing: WindowsCore.look(of: stage.id)))")
        expect(WindowsCore.measure?.text == "← 35°", "and the side and the angle are said by the pointer", "\(String(describing: WindowsCore.measure))")
        expect(hand.drag(to: CGPoint(x: 250, y: 260), steps: true) && WindowsCore.look(of: stage.id)?.across == 20 && WindowsCore.measure?.text == "→ 20°",
               "with Shift it goes in fives", "\(String(describing: WindowsCore.look(of: stage.id)))")
        expect(hand.cancel() && !WindowsCore.lookingFromTheSide && WindowsCore.measure == nil && !hand.dragging, "Escape during the drag looks as before it")
        _ = hand.down(at: CGPoint(x: 300, y: 260))
        hand.drag(to: CGPoint(x: 400, y: 260), steps: false)
        expect(!hand.up() && WindowsCore.look(of: stage.id)?.across == -35 && WindowsCore.measure == nil, "let go, the artboard stays looked at so")
        _ = hand.down(at: CGPoint(x: 300, y: 260))
        hand.drag(to: CGPoint(x: 200, y: 300), steps: false)
        expect(WindowsCore.look(of: stage.id)?.across == 0 && WindowsCore.look(of: stage.id)?.down == -14 && WindowsCore.measure?.text == "↑ 14°",
               "a second drag goes on from there", "\(String(describing: WindowsCore.look(of: stage.id))) \(String(describing: WindowsCore.measure))")
        hand.up()
        _ = hand.down(at: CGPoint(x: 300, y: 260))
        expect(hand.up() && !WindowsCore.lookingFromTheSide, "an Alt click looks from the front again")
        hand.focused = 1
        expect(hand.down(at: CGPoint(x: 450, y: 600)) && hand.board == wide.id, "beside every artboard, the one being worked on is taken")
        hand.cancel()
        hand.focused = nil
        expect(!hand.down(at: CGPoint(x: 450, y: 600)) && !hand.dragging, "and with none worked on, nothing")

        // Each open design is looked at in its own way.
        WindowsCore.look(at: stage.id, across: -45, down: 0)
        let (other, _) = try self.open("Other", [board([card("Up", CGRect(x: 100, y: 100, width: 50, height: 50), z: 30)], name: "Else")])
        expect(!WindowsCore.lookingFromTheSide && doc.looks == nil, "a design opened beside it is looked at from the front")
        WindowsCore.look(at: doc.nodes[0].id, across: 30, down: 0)
        let first = WindowsCore.using(slot) { WindowsCore.look(of: stage.id)?.across }
        expect(first == -45 && WindowsCore.look(of: doc.nodes[0].id)?.across == 30, "and each keeps its own way of looking", "\(String(describing: first))")
        WindowsCore.closeSlot(other)
        WindowsCore.activate(slot)
        expect(WindowsCore.look(of: stage.id)?.across == -45 && doc.looks?[stage.id] == DepthLook(across: -45), "back in the first, it is looked at as it was")

        // From the front again, all of them; and what was exported from the side is what the front exports.
        expect(WindowsCore.lookFromTheFront() && doc.looks == nil && !WindowsCore.lookingFromTheSide && !WindowsCore.lookFromTheFront(), "every artboard is looked at from the front again")
        expect(WindowsCore.boards().map(\.drawn) == frontBoards.map(\.drawn), "and is drawn as far as it was")
        let ahead = await WindowsCore.export("all", format: "png", scale: 1, quality: 0.9, selection: [], to: fromFront, replacing: true) { _ in }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: fromFront.path)) ?? []).sorted()
        let same = names.allSatisfy { name in
            guard let a = try? Data(contentsOf: fromSide.appendingPathComponent(name)), let b = try? Data(contentsOf: fromFront.appendingPathComponent(name)) else { return false }
            return a == b
        }
        expect(aside.written == 2 && ahead.written == 2 && names.count == 2 && same, "artboards exported while looked at from the side are the files the front exports",
               "\(aside.written) and \(ahead.written) written, \(names)")
    }

    // MARK: The AI server

    func call(_ tools: MCPTools, _ name: String, _ arguments: [String: Any]) async -> (text: String, failed: Bool, whole: String) {
        let result = await tools.call(name, arguments)
        let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        let content = object?["content"] as? [[String: Any]] ?? []
        return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true, result.text)
    }

    func assistant() async throws {
        said.append("The AI server")
        let scene = cardAndButton + [group("Group", CGRect(x: 20, y: 210, width: 120, height: 70), [
            card("Low", CGRect(x: 0, y: 0, width: 120, height: 70)),
            card("High", CGRect(x: 30, y: 20, width: 40, height: 30), z: 30, color: blue),
        ], keeps: false), card("Lifted", CGRect(x: 330, y: 20, width: 40, height: 40), z: 40, color: red)]
        let (slot, _) = try open("Assistant", [board(scene)])
        let designs = MCPHost.shared.designs
        MCPHost.shared.designs = { [slot] }
        defer {
            MCPHost.shared.designs = designs
            WindowsCore.closeSlot(slot)
        }
        let tools = MCPTools()
        let ids = [node("Card").id, node("Button").id]
        let before = doc

        // turn_layers.
        expect(tools.has("turn_layers"), "turn_layers is among its tools")
        let turned = await call(tools, "turn_layers", ["layers": ["Card", "Button"], "x": 10, "y": 40])
        var expected = before
        expected.turnInDepth(ids) { _, _ in Transform3D(x: 10, y: 40) }
        expect(!turned.failed && doc.nodes[0].children == expected.nodes[0].children, "turn_layers turns a card and its button as one body", turned.text)
        expect(WindowsCore.undo() && doc == before && !WindowsCore.undo(), "in one step")
        WindowsCore.redo()
        let flat = await call(tools, "turn_layers", ["layers": ["Card", "Button"], "x": 0, "y": 0])
        expect(!flat.failed && near(node("Button").frame, CGRect(x: 240, y: 140, width: 40, height: 20)) && near(node("Card").frame, CGRect(x: 100, y: 100, width: 200, height: 100)),
               "x 0 and y 0 lay it flat where it lay", "\(node("Button").frame)")
        let design = doc
        let posed = await call(tools, "turn_layers", ["layers": ["Card", "Button"], "y": 30, "time": 1])
        let button = node("Button")
        expect(!posed.failed && button.frame == design.allNodes.first { $0.name == "Button" }?.frame && button.transform3D == Transform3D(z: 20),
               "with time the design is left as it is", posed.text)
        expect(button.value(of: .swing, at: 1) == [30] && button[track: .move] != nil && button[track: .lift] != nil && node("Card").value(of: .swing, at: 1) == [30],
               "and both are posed so in the film, swung, moved and lifted with keys", "\(button.value(of: .swing, at: 1))")
        let board = await call(tools, "turn_layers", ["layers": ["Stage"], "y": 10])
        expect(board.failed && board.text.contains("An artboard is the page itself"), "an artboard is not turned, and it says so", board.text)
        let nothing = await call(tools, "turn_layers", ["layers": ["Card"]])
        expect(nothing.failed, "nor is anything with nothing said", nothing.text)

        // keepsDepth.
        let steps = doc
        let told = await call(tools, "update_layers", ["updates": [["layer": "Group", "keepsDepth": true]]])
        expect(!told.failed && node("Group").keepsDepth == true && node("Group").opensInDepth, "update_layers tells a group to keep its layers' depth", told.text)
        let listed = await call(tools, "get_layers", ["layers": ["Group"]])
        expect(listed.text.contains("\"keepsDepth\":true") || listed.text.contains("\"keepsDepth\": true"), "get_layers says so", listed.text)
        expect(WindowsCore.undo() && doc == steps && node("Group").keepsDepth == nil, "in one step")
        _ = await call(tools, "update_layers", ["updates": [["layer": "Group", "keepsDepth": true]]])
        _ = await call(tools, "update_layers", ["updates": [["layer": "Group", "keepsDepth": false]]])
        expect(node("Group").keepsDepth == nil, "false makes it one card again, with no key left")
        let plain = await call(tools, "get_layers", ["layers": ["Group"]])
        expect(!plain.text.contains("keepsDepth"), "and get_layers says nothing of it")
        let leaf = await call(tools, "update_layers", ["updates": [["layer": "Low", "keepsDepth": true]]])
        expect(leaf.whole.contains("Only a group") && node("Low").keepsDepth == nil, "only a group can be told, and it says so", leaf.text)

        // What an assistant is shown is from the front.
        let stage = doc.nodes[0]
        let frontLayer = await call(tools, "render", ["layer": "Lifted", "scale": 1])
        let frontBoard = await call(tools, "render", ["layer": "Stage", "scale": 1])
        WindowsCore.look(at: stage.id, across: -45, down: 0)
        let sideLayer = await call(tools, "render", ["layer": "Lifted", "scale": 1])
        let sideBoard = await call(tools, "render", ["layer": "Stage", "scale": 1])
        expect(WindowsCore.lookingFromTheSide && !frontLayer.failed && frontLayer.whole.contains("image/png") && frontLayer.whole == sideLayer.whole,
               "a layer drawn for an assistant is the same picture while its artboard is looked at from the side", frontLayer.text + " / " + sideLayer.text)
        expect(!frontBoard.failed && frontBoard.whole.contains("image/png") && frontBoard.whole == sideBoard.whole, "and so is the artboard", frontBoard.text + " / " + sideBoard.text)
        WindowsCore.lookFromTheFront()
    }
}
