import Testing
import AppKit
@testable import Bezzle

/// A page's 3D transforms brought into the design in depth (`WebDepth`): read by WebKit, each
/// element the design can say stands in the artboard's scene so that the design's own matrices
/// put its four corners where the browser draws them, measured in the page itself; what the
/// design cannot say lies flat as before, and the report says why.
@MainActor
@Suite(.serialized)
struct WebDepthTests {
    /// The page's scene, as large as the 800 by 600 artboard and seen from its eye: 1600 points
    /// in front of its middle, as Bezzle's own hand-off writes an artboard (`Inspect`).
    static let scene = ".scene { position: absolute; left: 0; top: 0; width: 800px; height: 600px; perspective: 1600px; perspective-origin: 50% 50%; }\n"

    /// Measures where each element marked `data-t` has its corners, in the page with its
    /// transforms on, by a point laid at each, and writes them as the page's title.
    static let measure = """
    <script>
    (() => {
      const out = {};
      for (const el of document.querySelectorAll('[data-t]')) {
        const cs = getComputedStyle(el);
        const bl = parseFloat(cs.borderLeftWidth) || 0, bt = parseFloat(cs.borderTopWidth) || 0;
        const w = el.offsetWidth, h = el.offsetHeight;
        out[el.dataset.t] = [[0, 0], [w, 0], [w, h], [0, h]].map(([x, y]) => {
          const p = document.createElement('i');
          p.style.cssText = 'position:absolute;display:block;width:0;height:0;margin:0;padding:0;border:0;transform:none;left:' + (x - bl) + 'px;top:' + (y - bt) + 'px';
          el.appendChild(p);
          const r = p.getBoundingClientRect();
          p.remove();
          return [r.left + scrollX, r.top + scrollY];
        });
      }
      document.title = JSON.stringify(out);
    })();
    </script>
    """

    /// The design a page makes, its report, the page as read, and where the browser draws the
    /// corners of each element marked.
    private func read(_ body: String, css: String) async throws -> (BezzleDocument, ImportReport, WebRead, [String: [CGPoint]]) {
        let (read, _) = try await WebTest.read(body + Self.measure, css: Self.scene + css)
        let (doc, report) = WebConverter.document([read], source: "test")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(read.page.title.utf8)) as? [String: [[Double]]])
        return (doc, report, read, json.mapValues { $0.map { CGPoint(x: $0[0], y: $0[1]) } })
    }

    /// Where the design shows a layer's corners on its artboard: through its own perspective, then
    /// each group's it lies in, seen from the artboard's eye.
    private func corners(_ doc: BezzleDocument, _ node: Node) -> [CGPoint] {
        let own = Perspective.corners(of: node, eye: doc.eye(forParentOf: node.id))
        guard let parent = doc.parent(of: node.id) else { return own }
        return own.map { doc.shown($0, inside: parent.id) }
    }

    /// The one layer drawn in a colour.
    private func layer(_ doc: BezzleDocument, _ r: Double, _ g: Double, _ b: Double) throws -> Node {
        let found = WebTest.filled(doc, RGBA(r: r / 255, g: g / 255, b: b / 255))
        #expect(found.count == 1, "one layer of rgb(\(Int(r)), \(Int(g)), \(Int(b)))")
        return try #require(found.first)
    }

    /// Whether the design shows a layer's corners within half a pixel of where the browser has them.
    private func agrees(_ doc: BezzleDocument, _ node: Node, _ browser: [CGPoint]?, _ what: String) -> Bool {
        guard let browser, browser.count == 4 else {
            Issue.record("the browser measured no corners of \(what)")
            return false
        }
        let shown = corners(doc, node)
        let off = zip(shown, browser).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? .infinity
        if off > 0.5 { Issue.record("\(what): the design shows its corners at \(shown), the browser at \(browser), \(off) apart") }
        return off <= 0.5
    }

    private func pixel(_ doc: BezzleDocument, _ p: CGPoint) throws -> NSColor {
        let board = try #require(doc.nodes.first)
        try #require(p.x.isFinite && p.y.isFinite && board.frame.contains(p), "\(p) lies on the artboard")
        let image = try #require(Renderer.tile(of: board, rect: CGRect(origin: .zero, size: board.frame.size), scale: 1, options: Renderer.Options()))
        let color = try #require(NSBitmapImageRep(cgImage: image).colorAt(x: Int(p.x), y: Int(p.y)))
        return try #require(color.usingColorSpace(.sRGB))
    }

    /// A point well inside a face as the browser draws it, off its diagonals: halfway from its
    /// middle to the middle of its top side.
    private func middle(_ quad: [CGPoint]?) -> CGPoint {
        guard let q = quad, q.count == 4 else { return CGPoint(x: -1, y: -1) }
        let c = CGPoint(x: q.map(\.x).reduce(0, +) / 4, y: q.map(\.y).reduce(0, +) / 4)
        let top = CGPoint(x: (q[0].x + q[1].x) / 2, y: (q[0].y + q[1].y) / 2)
        return CGPoint(x: (c.x + top.x) / 2, y: (c.y + top.y) / 2)
    }

    // MARK: In depth

    /// A card that keeps its depth, swung, with a face on each side: the back turned away, which
    /// the page hides, is there but hidden, so the front shows.
    @Test(.timeLimit(.minutes(5))) func flipsACardWithAFaceOnEachSide() async throws {
        let css = """
        .card { position: absolute; left: 300px; top: 200px; width: 200px; height: 140px; transform-style: preserve-3d; transform: rotateY(-35deg); }
        .face { position: absolute; left: 0; top: 0; width: 200px; height: 140px; backface-visibility: hidden; }
        .front { background: rgb(255, 0, 0); }
        .back { background: rgb(0, 0, 255); transform: rotateY(180deg); }
        """
        let body = #"<div class="scene"><div class="card"><div class="face front" data-t="front"></div><div class="face back" data-t="back"></div></div></div>"#
        let (doc, report, _, browser) = try await read(body, css: css)
        let front = try layer(doc, 255, 0, 0), back = try layer(doc, 0, 0, 255)
        #expect(agrees(doc, front, browser["front"], "the front"))
        #expect(agrees(doc, back, browser["back"], "the back"))
        // One group, swung as the card is, its faces lying in it, the back turned right round.
        let card = try #require(doc.parent(of: front.id))
        #expect(card.isGroup && doc.parent(of: back.id)?.id == card.id)
        #expect(card.transform3D?.y == -35 && card.transform3D?.x == 0 && card.keepsDepth == true)
        #expect(front.transform3D == nil && !front.hidden)
        #expect(back.hidden && abs(back.transform3D?.y ?? 0) == 180 && back.transform3D?.x == 0)
        #expect(report.notes.keys.contains("Faces turned away that the page hides, hidden"))
        #expect(!report.notes.keys.contains { $0.contains("drawn flat") })
        // Drawn, the front is what shows.
        let seen = try pixel(doc, middle(browser["front"]))
        #expect(seen.redComponent > 0.9 && seen.blueComponent < 0.1)
    }

    /// A plate that keeps its depth, tipped and stretched in depth, with chips held up off it; a
    /// panel turned as one card, what it holds lying on it; and a stack stretched in depth by the
    /// scale property alone, lifting what it holds twice as high.
    @Test(.timeLimit(.minutes(5))) func liftsChipsOffATippedPlateAndTurnsACard() async throws {
        let css = """
        .plate { position: absolute; left: 150px; top: 150px; width: 300px; height: 200px; background: rgb(200, 200, 200); transform-style: preserve-3d; transform: rotateX(35deg) scaleZ(2); }
        .stack { position: absolute; left: 560px; top: 440px; width: 120px; height: 80px; background: rgb(120, 200, 255); transform-style: preserve-3d; scale: 1 1 2; }
        .lift { position: absolute; left: 20px; top: 20px; width: 50px; height: 30px; background: rgb(255, 60, 60); transform: translateZ(20px); }
        .chip { position: absolute; width: 60px; height: 40px; }
        .a { left: 30px; top: 30px; background: rgb(255, 128, 0); transform: translateZ(30px); }
        .b { left: 180px; top: 110px; background: rgb(0, 160, 80); transform: translateZ(60px) rotate(20deg); }
        .panel { position: absolute; left: 520px; top: 180px; width: 200px; height: 220px; background: rgb(40, 40, 120); transform: rotateY(28deg); }
        .label { position: absolute; left: 20px; top: 20px; width: 100px; height: 30px; background: rgb(250, 250, 0); }
        """
        let body = """
        <div class="scene">
        <div class="plate" data-t="plate"><div class="chip a" data-t="a"></div><div class="chip b" data-t="b"></div></div>
        <div class="panel" data-t="panel"><div class="label" data-t="label"></div></div>
        <div class="stack" data-t="stack"><div class="lift" data-t="lift"></div></div>
        </div>
        """
        let (doc, report, _, browser) = try await read(body, css: css)
        let plate = try layer(doc, 200, 200, 200), a = try layer(doc, 255, 128, 0), b = try layer(doc, 0, 160, 80)
        let panel = try layer(doc, 40, 40, 120), label = try layer(doc, 250, 250, 0)
        let stack = try layer(doc, 120, 200, 255), lift = try layer(doc, 255, 60, 60)
        for (node, mark) in [(plate, "plate"), (a, "a"), (b, "b"), (panel, "panel"), (label, "label"), (stack, "stack"), (lift, "lift")] {
            #expect(agrees(doc, node, browser[mark], mark))
        }
        // The plate's group is tipped and keeps its depth; the chips are held up in it, twice as
        // high as they are moved, as the plate is stretched so in depth.
        let held = try #require(doc.parent(of: plate.id))
        #expect(held.transform3D?.x == 35 && held.transform3D?.y == 0 && held.keepsDepth == true)
        #expect(doc.parent(of: a.id)?.id == held.id && doc.parent(of: b.id)?.id == held.id)
        #expect(plate.transform3D == nil && a.transform3D?.z == 60 && b.transform3D?.z == 120)
        #expect(a.transform3D?.x == 0 && a.transform3D?.y == 0 && abs(b.rotation - 20) < 0.01)
        // The stack lies flat, keeping the depth of what it holds, which stands twice as high.
        #expect(stack.transform3D == nil && lift.transform3D?.z == 40 && doc.parent(of: lift.id)?.keepsDepth == true)
        // The panel is one card: turned, not keeping depth, what it holds lying in it.
        let card = try #require(doc.parent(of: panel.id))
        #expect(card.transform3D?.y == 28 && card.keepsDepth == nil)
        #expect(doc.parent(of: label.id)?.id == card.id && label.transform3D == nil)
        #expect(report.notes.isEmpty, "\(report.notes)")
    }

    /// A card turned as one with what a card holds on a page: words, a pseudo-element, and a
    /// rounded edge cutting off what reaches past it. All of it lies flat in the card's plane.
    @Test(.timeLimit(.minutes(5))) func turnsWordsAndPseudoElementsWithTheirCard() async throws {
        let css = """
        .tile { position: absolute; left: 260px; top: 160px; width: 260px; height: 200px; background: rgb(240, 240, 250); border-radius: 16px; overflow: hidden; transform: rotateX(-20deg) rotateY(30deg); font-size: 22px; }
        .tile::after { content: ""; position: absolute; right: 16px; top: 16px; width: 30px; height: 30px; background: rgb(0, 200, 0); }
        .tile p { position: absolute; left: 20px; top: 70px; margin: 0; color: rgb(20, 20, 20); }
        .wide { position: absolute; left: -20px; top: 150px; width: 300px; height: 30px; background: rgb(200, 0, 120); }
        """
        let body = #"<div class="scene"><div class="tile" data-t="tile"><p>Turned words</p><div class="wide" data-t="wide"></div></div></div>"#
        let (doc, report, _, browser) = try await read(body, css: css)
        let tile = try layer(doc, 240, 240, 250), wide = try layer(doc, 200, 0, 120), dot = try layer(doc, 0, 200, 0)
        let words = try #require(doc.allNodes.first { $0.text == "Turned words" })
        #expect(agrees(doc, tile, browser["tile"], "the tile"))
        #expect(agrees(doc, wide, browser["wide"], "the bar"))
        // The card is one group turned as the tile is, cut to its round edge; all it holds lies flat in it.
        let card = try #require(doc.allNodes.first { $0.isGroup && $0.transform3D != nil })
        #expect(card.transform3D?.x == -20 && card.transform3D?.y == 30 && card.keepsDepth == nil)
        for n in [tile, wide, dot, words] {
            #expect(doc.ancestors(of: n.id).contains { $0.id == card.id } && n.transform3D == nil, "\(n.name) lies flat in the card")
        }
        #expect(doc.allNodes.contains { $0.isMask && doc.ancestors(of: $0.id).contains { $0.id == card.id } || $0.id == card.id && $0.isMask })
        // The pseudo-element and the words where the page lays them out in the tile.
        let tileFrame = try #require(doc.absoluteFrame(of: tile.id)), dotFrame = try #require(doc.absoluteFrame(of: dot.id))
        #expect(WebTest.close(dotFrame, CGRect(x: tileFrame.maxX - 46, y: tileFrame.minY + 16, width: 30, height: 30), 0.01))
        #expect(WebTest.close(doc.absoluteFrame(of: wide.id) ?? .zero, CGRect(x: tileFrame.minX - 20, y: tileFrame.minY + 150, width: 300, height: 30), 0.001))
        #expect(abs((doc.absoluteFrame(of: words.id)?.minX ?? 0) - (tileFrame.minX + 20)) < 0.6)
        #expect(report.notes.isEmpty, "\(report.notes)")
    }

    /// A cube of six faces in a group that keeps their depth, turned two ways: every face where
    /// the browser has it, and the one in front drawn over the rest.
    @Test(.timeLimit(.minutes(5))) func buildsACubeOfSixFaces() async throws {
        let css = """
        .cube { position: absolute; left: 350px; top: 250px; width: 100px; height: 100px; transform-style: preserve-3d; transform: rotateX(-25deg) rotateY(35deg); }
        .cube div { position: absolute; left: 0; top: 0; width: 100px; height: 100px; }
        .f1 { background: rgb(255, 0, 0); transform: translateZ(50px); }
        .f2 { background: rgb(0, 255, 0); transform: rotateY(180deg) translateZ(50px); }
        .f3 { background: rgb(0, 0, 255); transform: rotateY(90deg) translateZ(50px); }
        .f4 { background: rgb(255, 255, 0); transform: rotateY(-90deg) translateZ(50px); }
        .f5 { background: rgb(255, 0, 255); transform: rotateX(90deg) translateZ(50px); }
        .f6 { background: rgb(0, 255, 255); transform: rotateX(-90deg) translateZ(50px); }
        """
        let body = #"<div class="scene"><div class="cube">"# + (1...6).map { #"<div class="f\#($0)" data-t="f\#($0)"></div>"# }.joined() + "</div></div>"
        let (doc, report, _, browser) = try await read(body, css: css)
        let colours: [(Double, Double, Double)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0), (255, 0, 255), (0, 255, 255)]
        var faces: [Node] = []
        for (i, c) in colours.enumerated() {
            let face = try layer(doc, c.0, c.1, c.2)
            faces.append(face)
            #expect(agrees(doc, face, browser["f\(i + 1)"], "face \(i + 1)"))
        }
        let cube = try #require(doc.parent(of: faces[0].id))
        #expect(cube.isGroup && cube.keepsDepth == true && faces.allSatisfy { doc.parent(of: $0.id)?.id == cube.id })
        #expect(faces.allSatisfy { Perspective.inDepth($0) })
        #expect(report.notes.isEmpty, "\(report.notes)")
        // The front face, nearest the eye, covers the rest where it is: red, not the yellow or
        // the magenta beside it (the picture is drawn wider than sRGB, so red leaks a little green).
        let seen = try pixel(doc, middle(browser["f1"]))
        #expect(seen.redComponent > 0.9 && seen.greenComponent < 0.5 && seen.blueComponent < 0.1, "\(seen) at \(middle(browser["f1"]))")
    }

    /// Groups that keep depth inside one another, each turned and held up in the one round it.
    @Test(.timeLimit(.minutes(5))) func nestsGroupsThatKeepDepth() async throws {
        let css = """
        .outer { position: absolute; left: 200px; top: 150px; width: 300px; height: 260px; background: rgb(30, 140, 200); transform-style: preserve-3d; transform: rotateY(25deg); }
        .inner { position: absolute; left: 40px; top: 40px; width: 200px; height: 150px; background: rgb(90, 30, 160); transform-style: preserve-3d; transform: translateZ(40px) rotateX(30deg); }
        .leaf { position: absolute; left: 50px; top: 40px; width: 80px; height: 50px; background: rgb(255, 200, 0); transform: translateZ(20px); }
        """
        let body = #"<div class="scene"><div class="outer" data-t="outer"><div class="inner" data-t="inner"><div class="leaf" data-t="leaf"></div></div></div></div>"#
        let (doc, report, _, browser) = try await read(body, css: css)
        let outer = try layer(doc, 30, 140, 200), inner = try layer(doc, 90, 30, 160), leaf = try layer(doc, 255, 200, 0)
        for (node, mark) in [(outer, "outer"), (inner, "inner"), (leaf, "leaf")] {
            #expect(agrees(doc, node, browser[mark], mark))
        }
        let outerGroup = try #require(doc.parent(of: outer.id)), innerGroup = try #require(doc.parent(of: inner.id))
        #expect(outerGroup.transform3D?.y == 25 && outerGroup.keepsDepth == true)
        #expect(doc.parent(of: innerGroup.id)?.id == outerGroup.id)
        #expect(innerGroup.transform3D?.x == 30 && innerGroup.transform3D?.y == 0 && innerGroup.keepsDepth == true)
        #expect(abs((innerGroup.transform3D?.z ?? 0) - 40) < 0.01)
        #expect(doc.parent(of: leaf.id)?.id == innerGroup.id && leaf.transform3D?.z == 20)
        #expect(report.notes.isEmpty, "\(report.notes)")
    }

    /// A perspective inside the transform itself, from the artboard's eye, stands in depth; one
    /// from nearer is drawn flat as before, and said so.
    @Test(.timeLimit(.minutes(5))) func seesThroughAPerspectiveInsideTheTransform() async throws {
        let css = """
        .solo { position: absolute; left: 300px; top: 250px; width: 200px; height: 100px; background: rgb(255, 80, 120); transform: perspective(1600px) rotateY(40deg); }
        .odd { position: absolute; left: 40px; top: 40px; width: 120px; height: 80px; background: rgb(10, 120, 10); transform: perspective(500px) rotateY(40deg); }
        """
        let body = #"<div class="solo" data-t="solo"></div><div class="odd" data-t="odd"></div>"#
        let (doc, report, read, browser) = try await read(body, css: css)
        let solo = try layer(doc, 255, 80, 120), odd = try layer(doc, 10, 120, 10)
        #expect(agrees(doc, solo, browser["solo"], "solo"))
        #expect(solo.transform3D?.y == 40 && solo.transform3D?.x == 0)
        // Drawn flat, where the page's flat matrix has always put it.
        #expect(odd.transform3D == nil)
        let item = try #require(WebTest.items(read.page).first { $0.bg == [10 / 255, 120 / 255, 10 / 255, 1] })
        let flat = try #require(item.matrix)
        let was = ImportGeometry.place(item.box, flat).map { ($0.frame, $0.rotation) } ?? (item.box.applying(flat), 0)
        #expect(WebTest.close(odd.frame, was.0, 0.01) && abs(odd.rotation - was.1) < 0.01)
        #expect(report.notes["3D transforms in a perspective other than the artboard’s, drawn flat"] == 1)
    }

    // MARK: Drawn flat

    /// A slant in depth is drawn flat as before; with no perspective at all, the page draws a
    /// turn in depth flat itself, and the design shows it just as flat, where the page has it.
    @Test(.timeLimit(.minutes(5))) func laysFlatWhatItCannotSay() async throws {
        let css = """
        .slant { position: absolute; left: 100px; top: 100px; width: 120px; height: 80px; background: rgb(120, 60, 0); transform: rotateY(30deg) skewY(15deg); }
        .ortho { position: absolute; left: 600px; top: 420px; width: 120px; height: 80px; background: rgb(20, 20, 20); transform: rotateZ(20deg) rotateX(60deg); }
        .ocube { position: absolute; left: 600px; top: 100px; width: 100px; height: 100px; transform-style: preserve-3d; transform: rotateY(30deg); }
        .oface { position: absolute; left: 0; top: 0; width: 100px; height: 100px; background: rgb(250, 120, 200); transform: rotateY(-60deg) translateZ(50px); }
        """
        let body = #"<div class="scene"><div class="slant" data-t="slant"></div></div><div class="ortho" data-t="ortho"></div><div class="ocube"><div class="oface" data-t="oface"></div></div>"#
        let (doc, report, read, browser) = try await read(body, css: css)
        let slant = try layer(doc, 120, 60, 0), ortho = try layer(doc, 20, 20, 20), oface = try layer(doc, 250, 120, 200)
        // Slanted: where the page's flat matrix has always put it.
        #expect(slant.transform3D == nil)
        let item = try #require(WebTest.items(read.page).first { $0.bg == [120 / 255, 60 / 255, 0, 1] })
        let m = try #require(item.matrix)
        #expect(ImportGeometry.place(item.box, m) == nil && WebTest.close(slant.frame, item.box.applying(m), 0.01))
        #expect(report.notes["Slanted 3D transforms, drawn flat"] == 1)
        // No perspective: flat, and where the browser draws it, a face in a cube that keeps
        // depth too, which the page's flat matrices alone would not put there.
        #expect(ortho.transform3D == nil && oface.transform3D == nil)
        #expect(agrees(doc, ortho, browser["ortho"], "ortho"))
        #expect(agrees(doc, oface, browser["oface"], "oface"))
        #expect(report.notes["3D transforms with no perspective, drawn flat as the page shows them"] == 3)
    }

    // MARK: Turns of every kind

    /// CSS's own matrices, as DOMMatrix keeps them (column by column), for pages written by hand.
    private enum CSSMatrix {
        static func of(_ rows: [[Double]]) -> WebMatrix { WebMatrix(columns: (0..<4).flatMap { c in (0..<4).map { r in rows[r][c] } }) }
        static func translate(_ x: Double, _ y: Double, _ z: Double = 0) -> WebMatrix { of([[1, 0, 0, x], [0, 1, 0, y], [0, 0, 1, z], [0, 0, 0, 1]]) }
        static func rotateX(_ deg: Double) -> WebMatrix {
            let c = cos(deg * .pi / 180), s = sin(deg * .pi / 180)
            return of([[1, 0, 0, 0], [0, c, -s, 0], [0, s, c, 0], [0, 0, 0, 1]])
        }
        static func rotateY(_ deg: Double) -> WebMatrix {
            let c = cos(deg * .pi / 180), s = sin(deg * .pi / 180)
            return of([[c, 0, s, 0], [0, 1, 0, 0], [-s, 0, c, 0], [0, 0, 0, 1]])
        }
        static func rotateZ(_ deg: Double) -> WebMatrix {
            let c = cos(deg * .pi / 180), s = sin(deg * .pi / 180)
            return of([[c, -s, 0, 0], [s, c, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]])
        }
        /// The artboard's eye as CSS writes it: perspective 1600px from the middle of 800 by 600.
        static let eye = translate(400, 300) * of([[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, -1 / 1600.0, 1]]) * translate(-400, -300)
        /// About a box's middle, as transform-origin has it by default.
        static func about(_ box: CGRect, _ m: WebMatrix) -> WebMatrix {
            translate(Double(box.midX), Double(box.midY)) * m * translate(-Double(box.midX), -Double(box.midY))
        }
        /// What a matrix draws onto the page: everything pressed into it.
        static func pressed(_ m: WebMatrix) -> WebMatrix {
            var n = m.m
            for c in 0..<4 { n[c * 4 + 2] = 0 }
            return WebMatrix(columns: n)
        }
    }

    /// An element as the reader hands it over, standing in the scene by `context`, inside the
    /// artboard-sized scene element 1, which sees through the artboard's eye.
    private func element(_ id: Int, _ box: CGRect, _ local: WebMatrix, context: WebMatrix, keeps: Bool = false, kids: [[String: Any]] = []) -> [String: Any] {
        let flat = [local[0, 0], local[1, 0], local[0, 1], local[1, 1], local[0, 3], local[1, 3]]
        var e: [String: Any] = ["t": "el", "id": id, "tag": "div", "label": "e\(id)", "x": box.minX, "y": box.minY, "w": box.width, "h": box.height,
                                "pos": "absolute", "sc": true, "bg": [0.5, 0.5, 0.5, 1], "ins": [0, 0, 0, 0, 0, 0, 0, 0], "m": flat,
                                "w3": CSSMatrix.pressed(context).m, "c3": context.m, "pl": 1, "o3": true]
        if keeps { e["p3"] = true }
        if !kids.isEmpty { e["kids"] = kids }
        return e
    }

    private func design(of elements: [[String: Any]]) throws -> BezzleDocument {
        let scene: [String: Any] = ["t": "el", "id": 1, "tag": "div", "x": 0, "y": 0, "w": 800, "h": 600, "ins": [0, 0, 0, 0, 0, 0, 0, 0], "kids": elements]
        let html: [String: Any] = ["t": "el", "id": 0, "tag": "html", "x": 0, "y": 0, "w": 800, "h": 600, "ins": [0, 0, 0, 0, 0, 0, 0, 0], "kids": [scene]]
        let root = String(decoding: try JSONSerialization.data(withJSONObject: html), as: UTF8.self)
        return WebTest.convert(try WebTest.page(root)).0
    }

    /// Where the page draws a box's corners by a matrix.
    private func drawn(_ box: CGRect, _ m: WebMatrix) -> [CGPoint] {
        [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
            .compactMap { CSSMatrix.pressed(m).shown($0) }
    }

    /// Every way a box can be tipped, swung, turned and lifted, beyond edge on and facing away,
    /// stands where the page draws it.
    @Test func standsEveryTurnAsThePageDoes() throws {
        var elements: [[String: Any]] = [], truth: [String: (CGRect, WebMatrix)] = [:]
        var id = 10
        for (i, tip) in [-150.0, -60, 0, 35, 95].enumerated() {
            for (j, swing) in [-120.0, -30, 0, 50, 170].enumerated() {
                for (k, twist) in [0.0, 25, -100].enumerated() {
                    let box = CGRect(x: 30 + Double(j) * 150 + Double(k) * 12, y: 30 + Double(i) * 110 + Double(k) * 8, width: 60, height: 36)
                    let local = CSSMatrix.about(box, CSSMatrix.translate(0, 0, Double(k) * 20) * CSSMatrix.rotateX(tip) * CSSMatrix.rotateY(swing) * CSSMatrix.rotateZ(twist))
                    let context = CSSMatrix.eye * local
                    elements.append(element(id, box, local, context: context))
                    truth["E\(id)"] = (box, context)
                    id += 1
                }
            }
        }
        let doc = try design(of: elements)
        for (name, (box, context)) in truth {
            let node = try #require(doc.allNodes.first { $0.name == name })
            let shown = corners(doc, node), page = drawn(box, context)
            let off = zip(shown, page).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? .infinity
            #expect(off < 0.01, "\(name): the design at \(shown), the page at \(page)")
        }
    }

    /// Groups that keep depth inside one another, each turned all three ways and lifted, with a
    /// card that does not keep it: every box where the page draws it, each group one layer.
    @Test func standsGroupsTurnedEveryWay() throws {
        let outerBox = CGRect(x: 200, y: 140, width: 360, height: 300)
        let midBox = CGRect(x: 260, y: 190, width: 200, height: 160)
        let leafBox = CGRect(x: 300, y: 220, width: 80, height: 50)
        let cardBox = CGRect(x: 420, y: 330, width: 110, height: 80)
        let inCardBox = CGRect(x: 430, y: 340, width: 40, height: 30)
        let outer = CSSMatrix.about(outerBox, CSSMatrix.rotateZ(20) * CSSMatrix.rotateY(-35) * CSSMatrix.rotateX(15))
        let mid = CSSMatrix.about(midBox, CSSMatrix.translate(0, 0, 50) * CSSMatrix.rotateX(-40) * CSSMatrix.rotateZ(-65))
        let leaf = CSSMatrix.about(leafBox, CSSMatrix.translate(0, 0, 30) * CSSMatrix.rotateY(70))
        let card = CSSMatrix.about(cardBox, CSSMatrix.translate(0, 0, 25) * CSSMatrix.rotateY(-50) * CSSMatrix.rotateZ(10))
        let outerContext = CSSMatrix.eye * outer, midContext = outerContext * mid, leafContext = midContext * leaf
        let cardContext = outerContext * card
        // What lies in the card is drawn into its plane, not into the scene.
        var inCard = element(16, inCardBox, CSSMatrix.translate(0, 0), context: CSSMatrix.translate(0, 0))
        inCard["w3"] = CSSMatrix.pressed(cardContext).m
        inCard["pl"] = 15
        inCard["o3"] = nil
        let elements = [element(12, outerBox, outer, context: outerContext, keeps: true, kids: [
            element(13, midBox, mid, context: midContext, keeps: true, kids: [element(14, leafBox, leaf, context: leafContext)]),
            element(15, cardBox, card, context: cardContext, kids: [inCard]),
        ])]
        let doc = try design(of: elements)
        for (name, box, context) in [("E12", outerBox, outerContext), ("E13", midBox, midContext), ("E14", leafBox, leafContext), ("E15", cardBox, cardContext), ("E16", inCardBox, cardContext)] {
            // The box itself: the layer of that name, or the background of the group of that name.
            let node = try #require(doc.allNodes.first { !$0.isGroup && ($0.name == name || $0.name == "Background" && doc.parent(of: $0.id)?.name == name) })
            let shown = corners(doc, node), page = drawn(box, context)
            let off = zip(shown, page).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? .infinity
            #expect(off < 0.01, "\(name): the design at \(shown), the page at \(page)")
        }
        // Each element is one group: those keeping depth keep it, the card is one card.
        let groups = doc.allNodes.filter { $0.isGroup }
        #expect(groups.filter { $0.keepsDepth == true }.map(\.name).sorted() == ["E12", "E13"])
        #expect(groups.first { $0.name == "E15" }.map { $0.keepsDepth == nil && $0.transform3D != nil } == true)
        #expect(groups.allSatisfy { $0.rotation == 0 })
    }

    // MARK: Pages without depth

    /// A page with nothing in depth hands over nothing more, and a perspective that sees nothing
    /// turned changes nothing.
    @Test(.timeLimit(.minutes(5))) func leavesPagesWithoutDepthAsTheyWere() async throws {
        let css = """
        .r { position: absolute; left: 100px; top: 100px; width: 120px; height: 60px; background: rgb(255, 0, 0); transform: rotate(30deg) scale(1.5); }
        .t { position: absolute; left: 400px; top: 300px; width: 80px; height: 80px; background: rgb(0, 0, 255); }
        p { position: absolute; left: 300px; top: 50px; margin: 0; font-size: 20px; transform: rotate(-10deg); }
        """
        let body = #"<div class="r"></div><div class="t"></div><p>Words turned in the page</p>"#
        let (plain, _) = try await WebTest.read(body, css: css)
        #expect(WebTest.items(plain.page).allSatisfy { $0.w3 == nil && $0.c3 == nil && $0.p3 == nil && $0.o3 == nil })
        let (seeing, _) = try await WebTest.read(#"<div class="scene">"# + body + "</div>", css: Self.scene + css)
        let (a, ra) = WebConverter.document([plain], source: "test"), (b, rb) = WebConverter.document([seeing], source: "test")
        func laid(_ doc: BezzleDocument) -> [String] {
            doc.allNodes.filter { !$0.isGroup && !$0.isArtboard }.map { n in
                let f = doc.absoluteFrame(of: n.id) ?? .zero
                return String(format: "%@ %.3f %.3f %.3f %.3f %.3f %@", n.kind.rawValue, f.minX, f.minY, f.width, f.height, n.rotation, n.transform3D == nil ? "flat" : "deep")
            }
        }
        #expect(laid(a) == laid(b))
        #expect(ra.notes == rb.notes)
    }
}
