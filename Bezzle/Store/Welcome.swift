import AppKit

/// The design a new Bezzle starts with: a short tour, laid out on the canvas as sheets one below
/// another. The first says hello and how to get about; each after it is a lesson, with what to try
/// in two or three steps down its left, and on its right the real thing to try it on: a sun to put
/// in the sky, a tile to round, a star to draw, a lemon to cut, a card to repeat, a stack of posts,
/// a card to tip in depth, a frame for a photo. Notes in blue pencil mark the sheets up, as a
/// designer marks up a proof.
///
/// What is there to read stays put, locked; what is there to try is free. Every word is in the
/// language Bezzle speaks when the tour is made: the first time Bezzle starts with no designs,
/// when it opens at once, and again from Help whenever it is asked for.
enum Welcome {
    /// The welcome sheet's id, the same in every copy, so the canvas can open on it (`DocumentStore.lookFirst`).
    static let coverID = UUID(uuidString: "BE22E1C0-0000-4000-8000-00000000C0FE")!

    private static let madeKey = "welcomeMade"

    /// Makes the tour and opens it the first time Bezzle starts with no designs. Only that once: it
    /// is not made again after it is thrown away, nor ever for someone who had designs already.
    static func makeOnFirstLaunch() {
        let settings = Library.settings
        guard !Library.isolated, !settings.bool(forKey: madeKey) else { return }
        settings.set(true, forKey: madeKey)
        guard Library.shared.entries.isEmpty, let url = make() else { return }
        WindowRouter.shared.open(url)
    }

    /// Help › Welcome to Bezzle: a fresh copy of the tour, opened.
    static func open() {
        if let url = make() { WindowRouter.shared.open(url) }
    }

    /// Writes a new copy of the tour into the Bezzle folder, and returns where it is.
    static func make() -> URL? {
        let url = Library.shared.freeURL(named: String(localized: "Welcome to Bezzle"))
        do {
            try DesignFile.write(design(), to: url)
            Library.shared.refresh()
            return url
        } catch {
            NSLog("Bezzle could not make the welcome tour at %@: %@", url.path, error.localizedDescription)
            return nil
        }
    }

    // MARK: The sheets

    private static let width: CGFloat = 880
    private static let gap: CGFloat = 150
    /// Where the words of a lesson run, and the mat at its right that the things to try lie on.
    private static let left: CGFloat = 56
    private static let column: CGFloat = 300

    /// The whole tour, one sheet below another.
    static func design() -> BezzleDocument {
        var doc = BezzleDocument()
        var top: CGFloat = 0
        // Each under the one before, so the layers list them from the first down.
        func place(_ sheet: Node, after extra: CGFloat = 0) {
            var s = sheet
            s.frame.origin = CGPoint(x: 0, y: top)
            doc.nodes.insert(s, at: 0)
            top = s.frame.maxY + gap + extra
        }
        place(cover())
        place(sheet(moving, number: 1))
        place(sheet(corners, number: 2))
        place(sheet(typing, number: 3))
        place(sheet(drawing, number: 4))
        place(sheet(cutting, number: 5))
        place(sheet(repeating, number: 6))
        let (stack, own) = stackSheet(number: 7)
        // Room under the stack for the posts behind it, which show below its foot.
        place(stack, after: 60)
        place(sheet(tipping, number: 8))
        place(sheet(lifting, number: 9))
        place(sheet(sharing, number: 10))

        // The stack is made as the app makes one, from the sheet and the words for each post.
        let store = DocumentStore(url: FileManager.default.temporaryDirectory, document: doc)
        store.spread(own.map { id, texts in (layer: id, fill: { (n: inout Node, i: Int) in n.text = texts[i] }) }, count: 3, action: "Make Posts")
        doc = store.doc
        doc.fitGroups()
        return doc
    }

    /// The first sheet: hello, how to get about, and a few shapes to push around.
    private static func cover() -> Node {
        var layers: [Node] = []
        var y: CGFloat = 60
        let kicker = words(String(localized: "A short tour"), Style.kicker, Ink.pencil, at: CGPoint(x: left, y: y))
        layers.append(kicker)
        y = kicker.frame.maxY + 12
        // As big as it can be in three lines, whatever the language makes of it.
        var title = Node(kind: .text, frame: .zero)
        for size in stride(from: CGFloat(62), through: 38, by: -4) {
            let style = TextStyle(family: "Charter", face: "Bold", size: size, lineSpacing: (size * 1.04).rounded())
            title = words(String(localized: "Welcome to Bezzle."), style, Ink.ink, at: CGPoint(x: left, y: y), width: 380)
            if title.frame.height <= style.lineSpacing! * 3 + 1 { break }
        }
        layers.append(title)
        y = title.frame.maxY + 18
        let lede = words(String(localized: "Every sheet below is a real design. Move things, change them, break them: ⌘Z puts it all back."),
                         TextStyle(size: 17, lineSpacing: 26), Ink.ink2, at: CGPoint(x: left, y: y), width: 350)
        layers.append(lede)
        y = lede.frame.maxY + 34

        let way = words(String(localized: "Finding your way"), Style.kicker, Ink.ink3, at: CGPoint(x: left, y: y))
        layers.append(way)
        y = way.frame.maxY + 14
        let rows: [([String], String)] = [
            (["⌘", "0"], String(localized: "See every sheet at once")),
            (["⌘", "+", "−"], String(localized: "Zoom in and out, or pinch")),
            ([String(localized: "Space")], String(localized: "Hold it and drag to move around, or just scroll")),
            (["⌘", "Z"], String(localized: "Undo anything, as often as you like")),
        ]
        let reach = rows.map { keys($0.0, at: .zero).width }.max() ?? 0
        for (labels, text) in rows {
            layers += keys(labels, at: CGPoint(x: left, y: y)).layers
            let line = words(text, Style.small, Ink.ink2, at: CGPoint(x: left + reach + 14, y: y + 3), width: 360 - reach - 14)
            layers.append(line)
            y = max(y + 24, line.frame.maxY) + 10
        }
        y += 26
        let count = words(String(localized: "Ten lessons, about a minute each."), Style.small, Ink.ink3, at: CGPoint(x: left, y: y))
        let start = note(String(localized: "Scroll down to start"), at: CGPoint(x: left, y: count.frame.maxY + 10), tilt: -3)
        layers += [count, start]
        let height = max(640, (start.frame.maxY + 76).rounded())
        let down = arrow(from: CGPoint(x: start.frame.maxX + 10, y: start.frame.midY), to: CGPoint(x: start.frame.maxX + 40, y: height - 18), bend: 18)

        var board = Node(kind: .artboard, name: String(localized: "Welcome"), frame: CGRect(x: 0, y: 0, width: width, height: height))
        board.id = coverID
        board.children = [read(title.name, layers), pointing(start, down)] + shapesToPlayWith(in: CGRect(x: 470, y: 0, width: 370, height: height))
        return board
    }

    /// A few bright shapes printed over one another, as a risograph prints its colours, for the
    /// welcome sheet: nothing to learn, only to push around.
    private static func shapesToPlayWith(in area: CGRect) -> [Node] {
        let o = CGPoint(x: area.minX, y: (area.midY - 262).rounded())
        var circle = shape(.ellipse, CGRect(x: o.x + 30, y: o.y, width: 210, height: 210), RGBA(hex: "3D6BE0")!)
        circle.blend = .multiply
        var square = shape(.rectangle, CGRect(x: o.x + 160, y: o.y + 140, width: 170, height: 170), RGBA(hex: "FF6F59")!)
        square.cornerRadius = 46
        square.cornerSmoothing = 0.6
        square.rotation = 14
        square.blend = .multiply
        var half = Trace()
        let c = CGPoint(x: o.x + 120, y: o.y + 400), r: CGFloat = 112, k = r * 0.5523
        half.move(c.x - r, c.y)
        half.curve(c.x - r, c.y - k, c.x - k, c.y - r, c.x, c.y - r)
        half.curve(c.x + k, c.y - r, c.x + r, c.y - k, c.x + r, c.y)
        half.close()
        var dome = path(half, fill: RGBA(hex: "FFC93C")!)
        dome.blend = .multiply
        var three = Trace()
        three.move(o.x + 210, o.y + 500)
        three.line(o.x + 285, o.y + 362)
        three.line(o.x + 360, o.y + 500)
        three.close()
        var triangle = path(three, fill: RGBA(hex: "4FB99F")!)
        triangle.blend = .multiply
        var ring = shape(.ellipse, CGRect(x: o.x + 292, y: o.y + 4, width: 62, height: 62), Ink.ink)
        ring.fill.on = false
        ring.border = Border(on: true, color: Ink.ink, width: 11, position: .inside)
        var dots: [Node] = []
        for row in 0..<4 {
            for column in 0..<6 {
                dots.append(shape(.ellipse, CGRect(x: o.x + 14 + CGFloat(column) * 16, y: o.y + 432 + CGFloat(row) * 16, width: 6, height: 6), Ink.ink.with(alpha: 0.28)))
            }
        }
        let hint = note(String(localized: "Go on, move one!"), at: CGPoint(x: o.x + 178, y: o.y + 520), tilt: -5)
        let pointer = arrow(from: CGPoint(x: hint.frame.minX - 8, y: hint.frame.minY + 4), to: CGPoint(x: o.x + 206, y: o.y + 386), bend: -20)
        return [circle, square, dome, triangle, ring, group(String(localized: "Dots"), dots), pointing(hint, pointer)]
    }

    /// A lesson: its title and steps, perhaps a key worth knowing, perhaps a last word, and what
    /// it is all tried on.
    private struct Lesson {
        var name: String
        var title: String
        var steps: [String]
        var keys: [String] = []
        var tip: String?
        var closing: String?
        /// The things to try, laid out on the mat whose frame it is given.
        var scene: @MainActor (CGRect) -> [Node]
    }

    /// A lesson's sheet: its words down the left, and its mat on the right with the things to try.
    /// Words that run long, as German ones do, make the sheet taller rather than crowd it.
    private static func sheet(_ lesson: Lesson, number: Int) -> Node {
        var layers: [Node] = []
        var y: CGFloat = 56
        let kicker = words(String(localized: "Lesson \(number)"), Style.kicker, Ink.pencil, at: CGPoint(x: left, y: y))
        let title = words(lesson.title, Style.headline, Ink.ink, at: CGPoint(x: left, y: kicker.frame.maxY + 10), width: column)
        layers += [kicker, title]
        y = title.frame.maxY + 24
        for (i, step) in lesson.steps.enumerated() {
            layers += badge(i + 1, at: CGPoint(x: left, y: y))
            let text = words(step, Style.body, Ink.ink2, at: CGPoint(x: left + 34, y: y), width: column - 34)
            layers.append(text)
            y = text.frame.maxY + 16
        }
        if let tip = lesson.tip {
            y += 8
            var x = left
            if !lesson.keys.isEmpty {
                let caps = keys(lesson.keys, at: CGPoint(x: left, y: y))
                layers += caps.layers
                x += caps.width + 10
            }
            let text = words(tip, Style.small, Ink.ink3, at: CGPoint(x: x, y: y + 3), width: left + column - x)
            layers.append(text)
            y = max(y + 24, text.frame.maxY) + 16
        }
        if let closing = lesson.closing {
            var rule = shape(.rectangle, CGRect(x: left, y: y + 6, width: 28, height: 2), Ink.pencil)
            rule.locked = true
            let text = words(closing, TextStyle(face: "Medium", size: 15, lineSpacing: 22), Ink.ink, at: CGPoint(x: left, y: y + 22), width: column)
            layers += [rule, text]
            y = text.frame.maxY + 16
        }
        let height = max(560, (y + 40).rounded())
        let mat = CGRect(x: 396, y: 40, width: 444, height: height - 80)
        var board = Node(kind: .artboard, name: lesson.name, frame: CGRect(x: 0, y: 0, width: width, height: height))
        board.children = [backdrop(mat), read(lesson.title, layers)] + lesson.scene(mat)
        return board
    }

    // MARK: The lessons

    private static let moving = Lesson(
        name: String(localized: "1. Move and turn"),
        title: String(localized: "Pick it up, put it down."),
        steps: [
            String(localized: "Drag the sun into the sky. When it lines up with something, a guide shows and it snaps into place."),
            String(localized: "Pull a corner of the sun to make it bigger. Hold ⇧ to keep it round."),
            String(localized: "Point just outside a corner of the poster: the pointer turns. Drag to rotate it."),
        ],
        keys: ["⌥"], tip: String(localized: "Hold it while dragging to leave a copy behind."),
        scene: sunAndPoster)

    private static func sunAndPoster(_ m: CGRect) -> [Node] {
        let p = CGPoint(x: m.minX + 44, y: (m.midY - 168).rounded())
        var sky = shape(.rectangle, CGRect(x: p.x, y: p.y, width: 240, height: 320), .white)
        sky.fill.gradient = linear(RGBA(hex: "A9CBEE")!, RGBA(hex: "F8DDBC")!, end: CGPoint(x: 0.5, y: 0.8))
        sky.shadow = Shadow(on: true, color: RGBA(r: 0.23, g: 0.2, b: 0.15, a: 0.18), x: 0, y: 12, blur: 30)
        var far = Trace()
        far.move(p.x, p.y + 236)
        far.curve(p.x + 60, p.y + 196, p.x + 140, p.y + 186, p.x + 240, p.y + 226)
        far.line(p.x + 240, p.y + 320)
        far.line(p.x, p.y + 320)
        far.close()
        var near = Trace()
        near.move(p.x, p.y + 262)
        near.curve(p.x + 80, p.y + 232, p.x + 160, p.y + 246, p.x + 240, p.y + 278)
        near.line(p.x + 240, p.y + 320)
        near.line(p.x, p.y + 320)
        near.close()
        var title = words(String(localized: "Summer"), TextStyle(family: "Charter", face: "Bold Italic", size: 28), .white, at: CGPoint(x: p.x + 20, y: p.y + 276))
        title.locked = false
        var target = shape(.ellipse, CGRect(x: p.x + 88, y: p.y + 60, width: 64, height: 64), Ink.pencil)
        target.fill.on = false
        target.border = Border(on: true, color: Ink.pencil, width: 1.5, position: .center, dash: 5, gap: 5)
        let poster = group(String(localized: "Poster"), [sky, path(far, fill: RGBA(hex: "9DC3A0")!), path(near, fill: RGBA(hex: "4F8A69")!), title, target])

        var sun = shape(.ellipse, CGRect(x: m.maxX - 112, y: (m.midY + 52).rounded(), width: 64, height: 64), Ink.sun)
        sun.name = String(localized: "Sun")
        sun.fill.gradient = Gradient(kind: .radial, stops: [GradientStop(offset: 0, color: RGBA(hex: "FFDB7A")!), GradientStop(offset: 1, color: RGBA(hex: "F5A524")!)],
                                     start: CGPoint(x: 0.4, y: 0.36), end: CGPoint(x: 0.4, y: 0.36), radius: 0.66)
        sun.shadow = Shadow(on: true, color: RGBA(hex: "F5A524", alpha: 0.5)!, x: 0, y: 6, blur: 22)
        let hint = note(String(localized: "into the sky!"), at: CGPoint(x: sun.frame.minX - 40, y: sun.frame.maxY + 18), tilt: -5)
        let pointer = arrow(from: CGPoint(x: sun.frame.midX + 6, y: sun.frame.minY - 12), to: CGPoint(x: p.x + 164, y: p.y + 98), bend: 34)
        return [poster, sun, pointing(hint, pointer)]
    }

    private static let corners = Lesson(
        name: String(localized: "2. Corners and shadows"),
        title: String(localized: "Shape it by hand."),
        steps: [
            String(localized: "Click the tile. Dots show inside its corners: drag one toward the middle to round every corner. Hold ⌥ to round just one."),
            String(localized: "Now grab the shadow, not the tile, and drag it to move the light."),
            String(localized: "Point at the choices in the inspector on the right. The tile tries each one on before you click."),
        ],
        keys: ["⌘", "D"], tip: String(localized: "Duplicates whatever is selected."),
        scene: tile)

    private static func tile(_ m: CGRect) -> [Node] {
        var tile = shape(.rectangle, CGRect(x: (m.midX - 104).rounded(), y: (m.midY - 92).rounded(), width: 184, height: 184), Ink.coral)
        tile.name = String(localized: "Tile")
        tile.shadow = Shadow(on: true, color: Ink.ink.with(alpha: 0.88), x: 16, y: 18, blur: 0)
        let f = tile.frame
        let round = note(String(localized: "round me"), at: CGPoint(x: f.minX - 26, y: f.minY - 70), tilt: -6)
        let toCorner = arrow(from: CGPoint(x: round.frame.minX + 18, y: round.frame.maxY + 2), to: CGPoint(x: f.minX + 13, y: f.minY + 12), bend: 16)
        let grab = note(String(localized: "grab my shadow"), at: CGPoint(x: f.midX - 10, y: f.maxY + 52), tilt: -3)
        let toShadow = arrow(from: CGPoint(x: grab.frame.maxX - 30, y: grab.frame.minY - 4), to: CGPoint(x: f.maxX + 8, y: f.maxY + 6), bend: 18)
        return [tile, pointing(round, toCorner), pointing(grab, toShadow)]
    }

    private static let typing = Lesson(
        name: String(localized: "3. Text"),
        title: String(localized: "Make it say something."),
        steps: [
            String(localized: "Double-click the headline on the poster and type something of your own."),
            String(localized: "Drag a side of the text to wrap its words. Drag its top or bottom to make the letters bigger or smaller."),
            String(localized: "Press T, then click anywhere for new text, or drag out a box for a paragraph."),
        ],
        keys: ["↩"], tip: String(localized: "Starts typing into the selected text."),
        scene: wordsOnPoster)

    private static func wordsOnPoster(_ m: CGRect) -> [Node] {
        let f = CGRect(x: (m.midX - 120).rounded(), y: (m.midY - 166).rounded(), width: 270, height: 340)
        var poster = shape(.rectangle, f, Ink.navy)
        poster.name = String(localized: "Poster")
        poster.cornerRadius = 4
        poster.shadow = Shadow(on: true, color: RGBA(r: 0.1, g: 0.12, b: 0.2, a: 0.22), x: 0, y: 14, blur: 32)
        poster.locked = true
        var headline = words(String(localized: "Your words here."), TextStyle(family: "Charter", face: "Bold", size: 44, lineSpacing: 46), .white,
                             at: CGPoint(x: f.minX + 26, y: f.minY + 30), width: 218)
        headline.locked = false
        var bar = shape(.rectangle, CGRect(x: f.minX + 26, y: f.maxY - 58, width: 36, height: 4), Ink.coral)
        bar.locked = true
        let credit = words(String(localized: "Set in Charter"), Style.kicker, RGBA(r: 1, g: 1, b: 1, a: 0.68), at: CGPoint(x: f.minX + 26, y: f.maxY - 44))
        let hint = note(String(localized: "double-click me"), at: CGPoint(x: f.minX - 54, y: f.minY - 50), tilt: -4)
        let pointer = arrow(from: CGPoint(x: hint.frame.minX + 30, y: hint.frame.maxY + 2), to: CGPoint(x: f.minX + 34, y: f.minY - 7), bend: 18)
        return [poster, headline, bar, credit, pointing(hint, pointer)]
    }

    private static let drawing = Lesson(
        name: String(localized: "4. Pen"),
        title: String(localized: "Join the dots."),
        steps: [
            String(localized: "Press P to pick up the pen."),
            String(localized: "Click dot 1, then 2, 3 and on round the star. Click dot 1 again to close the shape."),
            String(localized: "Drag as you click to pull a curve instead of a corner. Later, double-click any shape to move its points."),
        ],
        keys: ["esc"], tip: String(localized: "Puts the pen down."),
        scene: star)

    private static func star(_ m: CGRect) -> [Node] {
        let c = CGPoint(x: m.midX, y: (m.midY + 18).rounded())
        let points = (0..<10).map { i -> CGPoint in
            let angle = (-90 + Double(i) * 36) * .pi / 180, r: CGFloat = i % 2 == 0 ? 142 : 60
            return CGPoint(x: (c.x + r * CGFloat(cos(angle))).rounded(), y: (c.y + r * CGFloat(sin(angle))).rounded())
        }
        var outline = Trace()
        outline.move(points[0].x, points[0].y)
        for p in points.dropFirst() { outline.line(p.x, p.y) }
        outline.close()
        var faint = path(outline, fill: nil)
        faint.border = Border(on: true, color: Ink.ink.with(alpha: 0.12), width: 1, position: .center, dash: 3, gap: 5)
        faint.locked = true
        var layers = [faint]
        for (i, p) in points.enumerated() {
            var dot = shape(.ellipse, CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10), i == 0 ? Ink.pencil : Ink.ink)
            dot.locked = true
            // Each number sits out from the middle, beyond its dot.
            let away = CGPoint(x: p.x - c.x, y: p.y - c.y), length = max(hypot(away.x, away.y), 1)
            var number = words(String(i + 1), TextStyle(face: "Semibold", size: 12), i == 0 ? Ink.pencil : Ink.ink3, at: .zero)
            number.frame.origin = CGPoint(x: (p.x + away.x / length * 18 - number.frame.width / 2).rounded(),
                                          y: (p.y + away.y / length * 18 - number.frame.height / 2).rounded())
            layers += [dot, number]
        }
        let hint = note(String(localized: "start here"), at: CGPoint(x: points[0].x + 46, y: points[0].y - 22), tilt: -4)
        let pointer = arrow(from: CGPoint(x: hint.frame.minX - 4, y: hint.frame.midY + 6), to: CGPoint(x: points[0].x + 12, y: points[0].y + 2), bend: -12)
        return [read(String(localized: "Dots"), layers), pointing(hint, pointer)]
    }

    private static let cutting = Lesson(
        name: String(localized: "5. Knife and pieces"),
        title: String(localized: "Cut it up, build it back."),
        steps: [
            String(localized: "Press K and drag the knife straight across the lemon. Press V, then pull the halves apart."),
            String(localized: "Drag a box around the three circles to select them, then press ⌥⌘B to build with their pieces."),
            String(localized: "Click a piece to make it a shape of its own, or drag across pieces to join them. Hold ⌥ to wipe pieces away. Press ↩ when you’re done."),
        ],
        keys: ["⌥", "⌘", "U"], tip: String(localized: "Union, Subtract and the rest are in the Object menu."),
        scene: lemonAndCircles)

    private static func lemonAndCircles(_ m: CGRect) -> [Node] {
        // The lemon low on the left, the circles high on the right, each note on its own side.
        let c = CGPoint(x: m.minX + 128, y: m.maxY - 150)
        var outline = Trace()
        outline.move(c.x - 84, c.y)
        outline.curve(c.x - 70, c.y - 12, c.x - 58, c.y - 60, c.x, c.y - 60)
        outline.curve(c.x + 58, c.y - 60, c.x + 70, c.y - 12, c.x + 84, c.y)
        outline.curve(c.x + 70, c.y + 12, c.x + 58, c.y + 60, c.x, c.y + 60)
        outline.curve(c.x - 58, c.y + 60, c.x - 70, c.y + 12, c.x - 84, c.y)
        outline.close()
        var lemon = path(outline, fill: RGBA(hex: "F4C531")!)
        lemon.name = String(localized: "Lemon")
        lemon.rotation = -14
        lemon.shadow = Shadow(on: true, color: RGBA(r: 0.45, g: 0.33, b: 0.05, a: 0.2), x: 0, y: 8, blur: 18)
        var shine = shape(.ellipse, CGRect(x: c.x - 44, y: c.y - 40, width: 46, height: 16), RGBA(r: 1, g: 1, b: 1, a: 0.45))
        shine.rotation = -20
        var cut = Node(kind: .line, frame: .zero)
        cut.setLineEnds(CGPoint(x: c.x - 120, y: c.y + 26), CGPoint(x: c.x + 118, y: c.y - 30))
        cut.border = Border(on: true, color: Ink.pencil, width: 1.5, position: .center, dash: 6, gap: 6)
        cut.locked = true
        let cutHint = note(String(localized: "cut here"), at: CGPoint(x: c.x - 118, y: c.y + 46), tilt: -6)

        let v = CGPoint(x: m.maxX - 118, y: m.minY + 190)
        let colours = [RGBA(hex: "7FA3EE")!, RGBA(hex: "F38B74")!, RGBA(hex: "F7CF5A")!]
        let offsets = [CGPoint(x: -32, y: -26), CGPoint(x: 32, y: -26), CGPoint(x: 0, y: 28)]
        let circles = zip(colours, offsets).map { colour, d -> Node in
            var n = shape(.ellipse, CGRect(x: v.x + d.x - 58, y: v.y + d.y - 58, width: 116, height: 116), colour)
            n.name = String(localized: "Circle")
            n.blend = .multiply
            return n
        }
        // Its right end kept at the mat's edge, however long the words.
        var boxHint = note(String(localized: "drag a box round us"), at: CGPoint(x: 0, y: m.minY + 30), tilt: -4)
        boxHint.frame.origin.x = (m.maxX - 18 - boxHint.frame.width).rounded()
        let pointer = arrow(from: CGPoint(x: boxHint.frame.midX, y: boxHint.frame.maxY + 4), to: CGPoint(x: v.x - 30, y: v.y - 88), bend: 14)
        return [lemon, shine, pointing(cutHint, cut)] + circles + [pointing(boxHint, pointer)]
    }

    private static let repeating = Lesson(
        name: String(localized: "6. Repeat grid"),
        title: String(localized: "One card, a whole list."),
        steps: [
            String(localized: "Click the card and press ⌘R. It becomes a repeat grid."),
            String(localized: "Pull the blue handle on its bottom edge downward. Every new card is a copy."),
            String(localized: "Change one card, its colour or its size, and they all follow. The words in each stay their own."),
        ],
        tip: String(localized: "Drop a folder of photos or a text file on a grid to fill every card at once."),
        scene: card)

    private static func card(_ m: CGRect) -> [Node] {
        let o = CGPoint(x: m.minX + 56, y: m.minY + 108)
        var back = shape(.rectangle, CGRect(x: o.x, y: o.y, width: 332, height: 78), .white)
        back.cornerRadius = 18
        back.cornerSmoothing = 0.6
        back.shadow = Shadow(on: true, color: RGBA(r: 0.23, g: 0.2, b: 0.15, a: 0.12), x: 0, y: 6, blur: 18)
        let avatar = shape(.ellipse, CGRect(x: o.x + 16, y: o.y + 16, width: 46, height: 46), RGBA(hex: "E3E9FA")!)
        var initials = words("AK", TextStyle(face: "Semibold", size: 15), Ink.pencil, at: .zero)
        initials.frame.origin = CGPoint(x: (avatar.frame.midX - initials.frame.width / 2).rounded(), y: (avatar.frame.midY - initials.frame.height / 2).rounded())
        let name = words("Anna Keller", TextStyle(face: "Semibold", size: 16), Ink.ink, at: CGPoint(x: o.x + 76, y: o.y + 18))
        let job = words(String(localized: "Product designer"), TextStyle(size: 13), Ink.ink3, at: CGPoint(x: o.x + 76, y: o.y + 41))
        var chevron = Trace()
        chevron.move(o.x + 304, o.y + 32)
        chevron.line(o.x + 311, o.y + 39)
        chevron.line(o.x + 304, o.y + 46)
        var more = path(chevron, fill: nil)
        more.border = Border(on: true, color: Ink.ink3, width: 2, position: .center)
        let card = group(String(localized: "Card"), [back, avatar, initials, name, job, more].map { var n = $0; n.locked = false; return n })
        let hint = note(String(localized: "click me, then ⌘R"), at: CGPoint(x: o.x + 120, y: o.y - 62), tilt: -4)
        let pointer = arrow(from: CGPoint(x: hint.frame.minX - 6, y: hint.frame.midY + 4), to: CGPoint(x: o.x + 70, y: o.y - 8), bend: 16)
        return [card, pointing(hint, pointer)]
    }

    /// The lesson on stacks is a stack itself: three posts that share one design, each saying its
    /// own part. Returns the sheet as one post, and the layers each post has its own words in,
    /// with the words for each.
    private static func stackSheet(number: Int) -> (Node, [(UUID, [String])]) {
        let titles = [
            String(localized: "This sheet is a stack."),
            String(localized: "Restyle one, restyle all."),
            String(localized: "Each post has its own words."),
        ]
        let bodies = [
            String(localized: "It holds three posts that share one design, like a series for social media. Click the cards peeking out below this sheet to spread them all out, then pick one."),
            String(localized: "Click the coloured panel and give it a new colour in the inspector. Then turn to the other posts with ⌥⌘← and ⌥⌘→: they changed too. Want it in this post only? Click Only This One."),
            String(localized: "Text and photos belong to each post. Press ⇧⌘P to add a post, a copy of the one in front. Export saves one post, or all of them at once."),
        ]
        let hints = [
            String(localized: "click the cards below"),
            String(localized: "or click the dots below"),
            String(localized: "⇧⌘P adds a fourth"),
        ]
        let kicker = words(String(localized: "Lesson \(number)"), Style.kicker, Ink.pencil, at: CGPoint(x: left, y: 56))
        // Each layer is as big as its longest words, the same in every post.
        let title = longest(titles, Style.headline, Ink.ink, at: CGPoint(x: left, y: kicker.frame.maxY + 10), width: column)
        let body = longest(bodies, Style.body, Ink.ink2, at: CGPoint(x: left, y: title.frame.maxY + 18), width: column)
        var hint = longest(hints, Style.note, Ink.pencil, at: CGPoint(x: left + 20, y: body.frame.maxY + 26), width: nil)
        hint.rotation = -4
        let height = max(560, (hint.frame.maxY + 84).rounded())
        // Down from under the note to the posts behind, clear of the panel however long the words.
        let pointer = arrow(from: CGPoint(x: hint.frame.midX + 10, y: hint.frame.maxY + 8), to: CGPoint(x: hint.frame.midX + 44, y: height - 14), bend: 16)

        var panel = shape(.rectangle, CGRect(x: 396, y: 40, width: 444, height: height - 80), Ink.coral)
        panel.name = String(localized: "Panel")
        panel.cornerRadius = 18
        panel.cornerSmoothing = 0.6
        let digits = ["1", "2", "3"]
        var figure = longest(digits, TextStyle(family: "Charter", face: "Black", size: 220, align: .center), .white,
                             at: CGPoint(x: panel.frame.minX, y: 0), width: panel.frame.width)
        figure.frame.origin.y = (panel.frame.midY - figure.frame.height / 2 - 8).rounded()

        var board = Node(kind: .artboard, name: String(localized: "7. Stacks"), frame: CGRect(x: 0, y: 0, width: width, height: height))
        board.children = [panel, figure, kicker, title, body, hint, pointer]
        return (board, [(title.id, titles), (body.id, bodies), (hint.id, hints), (figure.id, digits)])
    }

    private static let tipping = Lesson(
        name: String(localized: "8. 3D"),
        title: String(localized: "Tip it into depth."),
        steps: [
            String(localized: "Click the card. Point just outside the middle of a side, then drag to turn the card in depth."),
            String(localized: "Drag the knob on its face to aim it, as if you led it by the nose. Hold ⌥ to bring it nearer or push it away."),
            String(localized: "Double-click the knob to lay the card flat again."),
        ],
        tip: String(localized: "The 3D section of the inspector has a pad to aim with, and exact degrees."),
        scene: memberCard)

    private static func memberCard(_ m: CGRect) -> [Node] {
        let f = CGRect(x: (m.midX - 150).rounded(), y: (m.midY - 84).rounded(), width: 300, height: 188)
        var back = shape(.rectangle, f, Ink.pencil)
        back.cornerRadius = 20
        back.cornerSmoothing = 0.6
        back.fill.gradient = linear(RGBA(hex: "3559C7")!, RGBA(hex: "7B5CF0")!, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1))
        back.shadow = Shadow(on: true, color: RGBA(r: 0.13, g: 0.12, b: 0.3, a: 0.3), x: 0, y: 18, blur: 34)
        let name = words("Bezzle", TextStyle(family: "Charter", face: "Bold", size: 24), .white, at: CGPoint(x: f.minX + 22, y: f.minY + 18))
        var chip = shape(.rectangle, CGRect(x: f.minX + 22, y: f.minY + 70, width: 42, height: 32), RGBA(hex: "F2CF6B")!)
        chip.cornerRadius = 7
        chip.fill.gradient = linear(RGBA(hex: "F7DE8A")!, RGBA(hex: "D9A53A")!, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1))
        let number = words("2026  1030  0001  4242", TextStyle(face: "Medium", size: 15, tracking: 60), .white, at: CGPoint(x: f.minX + 22, y: f.minY + 118))
        let holder = words(String(localized: "Your name"), Style.kicker, RGBA(r: 1, g: 1, b: 1, a: 0.75), at: CGPoint(x: f.minX + 22, y: f.minY + 152))
        var card = group(String(localized: "Card"), [back, name, chip, number, holder].map { var n = $0; n.locked = false; return n })
        card.transform3D = Transform3D(x: 12, y: -24)
        let hint = note(String(localized: "grab just outside a side"), at: CGPoint(x: f.minX - 6, y: f.maxY + 54), tilt: -3)
        let pointer = arrow(from: CGPoint(x: hint.frame.maxX + 6, y: hint.frame.minY + 2), to: CGPoint(x: f.maxX + 16, y: f.midY + 14), bend: 26)
        return [card, pointing(hint, pointer)]
    }

    private static let lifting = Lesson(
        name: String(localized: "9. Remove background"),
        title: String(localized: "Lift out what matters."),
        steps: [
            String(localized: "Drag a photo of a person, a pet or a thing from the Finder or Photos onto the frame."),
            String(localized: "With the photo selected, choose Subject alone in the inspector. Bezzle finds the subject right on your Mac."),
            String(localized: "Double-click the photo to move or scale it inside the frame. The original is always kept."),
        ],
        scene: photoFrame)

    private static func photoFrame(_ m: CGRect) -> [Node] {
        let f = CGRect(x: (m.midX - 150).rounded(), y: (m.midY - 130).rounded(), width: 300, height: 236)
        // What shows until a photo is dropped: under the frame, which is clear, so a photo dropped
        // anywhere on it goes into the frame and covers it all.
        var well = shape(.rectangle, f, RGBA(hex: "EEF3EF")!)
        well.cornerRadius = 22
        well.cornerSmoothing = 0.6
        well.border = Border(on: true, color: Ink.sage, width: 1.5, position: .inside, dash: 7, gap: 6)
        well.locked = true
        var hills = Trace()
        let g = CGPoint(x: f.midX - 34, y: f.midY - 34)
        hills.move(g.x, g.y + 52)
        hills.line(g.x + 22, g.y + 24)
        hills.line(g.x + 36, g.y + 40)
        hills.line(g.x + 48, g.y + 30)
        hills.line(g.x + 68, g.y + 52)
        hills.close()
        var glyph = path(hills, fill: Ink.sage)
        glyph.locked = true
        var sun = shape(.ellipse, CGRect(x: g.x + 44, y: g.y + 4, width: 14, height: 14), Ink.sage)
        sun.locked = true
        var label = words(String(localized: "Drop a photo here"), TextStyle(face: "Medium", size: 14), RGBA(hex: "6E8F78")!, at: .zero)
        label.frame.origin = CGPoint(x: (f.midX - label.frame.width / 2).rounded(), y: g.y + 66)
        var frame = shape(.rectangle, f, RGBA(r: 1, g: 1, b: 1, a: 0))
        frame.name = String(localized: "Photo frame")
        frame.cornerRadius = 22
        frame.cornerSmoothing = 0.6
        let hint = note(String(localized: "a person, a pet, a teapot…"), at: CGPoint(x: f.minX + 14, y: f.maxY + 26), tilt: -3)
        return [read(label.name, [well, glyph, sun, label]), frame, hint]
    }

    private static let sharing = Lesson(
        name: String(localized: "10. Share and export"),
        title: String(localized: "Send it out into the world."),
        steps: [
            String(localized: "Press ⌘E to export an artboard, a layer or every post of a stack as PNG, JPEG, SVG or PDF."),
            String(localized: "Click Share… at the top to invite anyone with a Mac. You design together over iCloud, and no one’s work is ever lost."),
            String(localized: "With Bezzle › Connect an AI Assistant, Claude or another assistant can design with you. Every step it takes can be undone."),
        ],
        closing: String(localized: "That’s the tour. Press ⌘N for a design of your own. Help › Welcome to Bezzle brings back a fresh copy of this one."),
        scene: files)

    private static func files(_ m: CGRect) -> [Node] {
        let kinds: [(String, RGBA, Double, CGFloat)] = [
            ("PNG", RGBA(hex: "7FA3EE")!, -11, -96), ("SVG", RGBA(hex: "4FB99F")!, 0, 0), ("PDF", Ink.coral, 11, 96),
        ]
        let c = CGPoint(x: m.midX, y: (m.midY - 30).rounded())
        var layers = kinds.map { label, colour, turn, dx -> Node in
            let f = CGRect(x: (c.x + dx - 64).rounded(), y: (c.y - 84 + abs(dx) * 0.16).rounded(), width: 128, height: 166)
            var paper = shape(.rectangle, f, .white)
            paper.cornerRadius = 8
            paper.border = Border(on: true, color: RGBA(hex: "E3DED5")!, width: 1, position: .inside)
            paper.shadow = Shadow(on: true, color: RGBA(r: 0.23, g: 0.2, b: 0.15, a: 0.16), x: 0, y: 10, blur: 26)
            var picture = shape(.rectangle, CGRect(x: f.minX + 14, y: f.minY + 14, width: f.width - 28, height: 62), colour.with(alpha: 0.28))
            picture.cornerRadius = 5
            let lines = [0.86, 0.62, 0.74].enumerated().map { i, share in
                var l = shape(.rectangle, CGRect(x: f.minX + 14, y: f.minY + 90 + CGFloat(i) * 13, width: ((f.width - 28) * share).rounded(), height: 6), Ink.ink.with(alpha: 0.09))
                l.cornerRadius = 3
                return l
            }
            var tag = shape(.rectangle, CGRect(x: f.minX + 14, y: f.maxY - 32, width: 44, height: 20), colour)
            tag.cornerRadius = 10
            var word = words(label, TextStyle(face: "Bold", size: 10, tracking: 60), .white, at: .zero)
            word.frame.origin = CGPoint(x: (tag.frame.midX - word.frame.width / 2).rounded(), y: (tag.frame.midY - word.frame.height / 2).rounded())
            var file = group(label, ([paper, picture] + lines + [tag, word]).map { var n = $0; n.locked = false; return n })
            file = BezzleDocument.turned(file, by: turn, about: CGPoint(x: f.midX, y: f.maxY + 60))
            return file
        }
        let hint = note(String(localized: "your turn!"), at: CGPoint(x: c.x - 40, y: c.y + 150), tilt: -5)
        layers.append(hint)
        return layers
    }

    // MARK: Making layers

    /// The tour's colours: the app's own ink and pencil, and a few bright ones to play with.
    private enum Ink {
        static let ink = RGBA(hex: "1C1B19")!
        static let ink2 = RGBA(hex: "5E5A54")!
        static let ink3 = RGBA(hex: "9A958D")!
        static let pencil = RGBA(hex: "3559C7")!
        static let mat = RGBA(hex: "F5F2EC")!
        static let key = RGBA(hex: "D6D1C7")!
        static let coral = RGBA(hex: "F06B4F")!
        static let sun = RGBA(hex: "F5B83D")!
        static let sage = RGBA(hex: "8FB39A")!
        static let navy = RGBA(hex: "1F3A5F")!
    }

    /// The tour's type: Charter for titles, the Mac's own for what is read, and a hand for notes.
    private enum Style {
        static let kicker = TextStyle(face: "Semibold", size: 11, tracking: 140, letterCase: .upper)
        static let headline = TextStyle(family: "Charter", face: "Bold", size: 34, lineSpacing: 38)
        static let body = TextStyle(size: 15, lineSpacing: 22)
        static let small = TextStyle(size: 13, lineSpacing: 19)
        static let note = TextStyle(family: "Bradley Hand", face: "Bold", size: 20)
    }

    /// Words at a point, locked: as wide as they are, or wrapped to `width`.
    private static func words(_ text: String, _ style: TextStyle, _ colour: RGBA, at p: CGPoint, width: CGFloat? = nil) -> Node {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        var n = Node(kind: .text, name: line.count > 40 ? String(line.prefix(40)) + "…" : line,
                     frame: CGRect(x: p.x, y: p.y, width: width ?? 0, height: 0))
        n.text = text
        n.style = style
        if width != nil, style.sizing == .autoWidth { n.style?.sizing = .autoHeight }
        n.fill.color = colour
        n.locked = true
        n.refit()
        return n
    }

    /// Words in a box as big as the longest of `texts` needs, for a layer that says each in turn.
    private static func longest(_ texts: [String], _ style: TextStyle, _ colour: RGBA, at p: CGPoint, width: CGFloat?) -> Node {
        let sizes = texts.map { words($0, style, colour, at: p, width: width).frame.size }
        var n = words(texts[0], style, colour, at: p, width: width)
        n.style?.sizing = .fixed
        n.frame.size = CGSize(width: width ?? (sizes.map(\.width).max() ?? 0), height: sizes.map(\.height).max() ?? 0)
        return n
    }

    /// A note in blue pencil, written by hand and a little askew.
    private static func note(_ text: String, at p: CGPoint, tilt: Double) -> Node {
        var n = words(text, Style.note, Ink.pencil, at: p)
        n.rotation = tilt
        return n
    }

    private static func shape(_ kind: Node.Kind, _ frame: CGRect, _ colour: RGBA) -> Node {
        var n = Node(kind: kind, frame: frame)
        n.fill.color = colour
        return n
    }

    private static func path(_ trace: Trace, fill: RGBA?) -> Node {
        let box = PathData.bounds(trace.data)
        var n = Node(kind: .path, frame: box)
        n.path = trace.data
        n.pathBox = box
        if let fill { n.fill.color = fill } else { n.fill.on = false }
        return n
    }

    /// Layers that are only there to be read, put together and locked, so a click goes past them.
    private static func read(_ name: String, _ layers: [Node]) -> Node {
        var g = group(name, layers)
        g.locked = true
        return g
    }

    /// A note and what it points with, kept together.
    private static func pointing(_ note: Node, _ pointer: Node) -> Node {
        read(note.name, [note, pointer])
    }

    /// Layers put together, the group fitted round them.
    private static func group(_ name: String, _ layers: [Node]) -> Node {
        let box = layers.map { Geometry.bounds(of: $0) }.reduce(CGRect.null) { $0.union($1) }
        var g = Node(kind: .group, name: name, frame: box)
        g.children = layers.map { var n = $0; n.frame = n.frame.offsetBy(dx: -box.minX, dy: -box.minY); return n }
        return g
    }

    private static func linear(_ from: RGBA, _ to: RGBA, start: CGPoint = CGPoint(x: 0.5, y: 0), end: CGPoint = CGPoint(x: 0.5, y: 1)) -> Gradient {
        Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: from), GradientStop(offset: 1, color: to)], start: start, end: end)
    }

    /// The warm mat a lesson's things lie on.
    private static func backdrop(_ frame: CGRect) -> Node {
        var n = shape(.rectangle, frame, Ink.mat)
        n.cornerRadius = 18
        n.cornerSmoothing = 0.6
        n.locked = true
        return n
    }

    /// A step's number in a pencil dot.
    private static func badge(_ number: Int, at p: CGPoint) -> [Node] {
        var dot = shape(.ellipse, CGRect(x: p.x, y: p.y, width: 22, height: 22), Ink.pencil.with(alpha: 0.1))
        dot.locked = true
        var digit = words(String(number), TextStyle(face: "Semibold", size: 12), Ink.pencil, at: .zero)
        digit.frame.origin = CGPoint(x: (p.x + 11 - digit.frame.width / 2).rounded(), y: (p.y + 11 - digit.frame.height / 2).rounded())
        return [dot, digit]
    }

    /// Keys as they look on the keyboard, side by side from `p`, and how far they reach.
    private static func keys(_ labels: [String], at p: CGPoint) -> (layers: [Node], width: CGFloat) {
        var layers: [Node] = [], x = p.x
        for label in labels {
            var word = words(label, TextStyle(face: "Medium", size: 12), Ink.ink, at: .zero)
            let w = max(24, (word.frame.width + 14).rounded())
            var cap = shape(.rectangle, CGRect(x: x, y: p.y, width: w, height: 24), .white)
            cap.cornerRadius = 6
            cap.border = Border(on: true, color: Ink.key, width: 1, position: .inside)
            cap.shadow = Shadow(on: true, color: Ink.key, x: 0, y: 1.5, blur: 0)
            cap.locked = true
            word.frame.origin = CGPoint(x: (x + (w - word.frame.width) / 2).rounded(), y: (p.y + (24 - word.frame.height) / 2).rounded())
            layers += [cap, word]
            x += w + 4
        }
        return (layers, max(x - 4 - p.x, 0))
    }

    /// A pencil arrow, drawn as by hand: a curve from `a` to `b` bowing `bend` points to its left,
    /// with a head at `b` pointing the way the curve arrives.
    private static func arrow(from a: CGPoint, to b: CGPoint, bend: CGFloat) -> Node {
        let d = CGPoint(x: b.x - a.x, y: b.y - a.y), length = max(hypot(d.x, d.y), 1)
        let mid = CGPoint(x: (a.x + b.x) / 2 + d.y / length * bend, y: (a.y + b.y) / 2 - d.x / length * bend)
        let c1 = CGPoint(x: a.x + (mid.x - a.x) * 2 / 3, y: a.y + (mid.y - a.y) * 2 / 3)
        let c2 = CGPoint(x: b.x + (mid.x - b.x) * 2 / 3, y: b.y + (mid.y - b.y) * 2 / 3)
        let t = CGPoint(x: b.x - c2.x, y: b.y - c2.y), tl = max(hypot(t.x, t.y), 1)
        func barb(_ angle: CGFloat) -> CGPoint {
            let u = CGPoint(x: t.x / tl, y: t.y / tl)
            return CGPoint(x: b.x - 10 * (u.x * cos(angle) - u.y * sin(angle)), y: b.y - 10 * (u.x * sin(angle) + u.y * cos(angle)))
        }
        var trace = Trace()
        trace.move(a.x, a.y)
        trace.curve(c1.x, c1.y, c2.x, c2.y, b.x, b.y)
        let l = barb(0.5), r = barb(-0.5)
        trace.move(l.x, l.y)
        trace.line(b.x, b.y)
        trace.line(r.x, r.y)
        var n = path(trace, fill: nil)
        n.border = Border(on: true, color: Ink.pencil, width: 2, position: .center)
        n.locked = true
        return n
    }

    /// An outline written as path data, point by point, in the sheet's own coordinates.
    private struct Trace {
        private(set) var data = ""
        mutating func move(_ x: CGFloat, _ y: CGFloat) { add("M", [x, y]) }
        mutating func line(_ x: CGFloat, _ y: CGFloat) { add("L", [x, y]) }
        mutating func curve(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat, _ y: CGFloat) { add("C", [x1, y1, x2, y2, x, y]) }
        mutating func close() { data += "Z" }
        private mutating func add(_ command: String, _ values: [CGFloat]) {
            data += command + values.map { PathData.number($0) }.joined(separator: " ") + " "
        }
    }
}
