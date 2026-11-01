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
            // The photo some lessons are tried on, into the design's own images.
            if let photo = WelcomePhoto.jpeg() {
                try photo.write(to: url.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true).appendingPathComponent(photoAsset))
            }
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
        var number = 0
        func lessons(_ all: [Lesson]) {
            for lesson in all {
                number += 1
                let (made, beside) = sheet(lesson, number: number)
                let y = top
                place(made)
                // Its foot level with its sheet's, where the sheet's note points; its right edge
                // where the other sheets end; listed after its sheet.
                if var beside {
                    beside.frame.origin = CGPoint(x: width - beside.frame.width, y: y + made.frame.height - beside.frame.height)
                    doc.nodes.insert(beside, at: 0)
                }
            }
        }
        place(cover())
        lessons([moving, corners, layering, typing, styling, painting, curving, drawing, cutting, repeating, linking, naming, darkening])
        number += 1
        let (stack, own) = stackSheet(number: number)
        // Room under the stack for the posts behind it, which show below its foot.
        place(stack, after: 60)
        lessons([lining, adapting, tipping, lifting, developing, framing, marking, sharing])

        // The stack is made as the app makes one, from the sheet and the words for each post.
        let store = DocumentStore(url: FileManager.default.temporaryDirectory, document: doc)
        store.spread(own.map { id, texts in (layer: id, fill: { (n: inout Node, i: Int) in n.text = texts[i] }) }, count: 3, action: "Make Posts")
        doc = store.doc
        // The buttons of the lesson on components are one component, as the app makes one.
        if let made = DocumentStore.makeComponent(from: [buttonIDs[0]], in: &doc, name: String(localized: "Pill button")),
           let master = doc.node(made)?.instance?.of {
            doc.fitGroups()
            for id in buttonIDs.dropFirst() { DocumentStore.link(id, to: master, in: &doc) }
        }
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
        let count = words(String(localized: "Twenty-two lessons, about a minute each."), Style.small, Ink.ink3, at: CGPoint(x: left, y: y))
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
        /// The sheet's name, with its number.
        var name: (Int) -> String
        var title: String
        var steps: [String]
        var keys: [String] = []
        var tip: String?
        var closing: String?
        /// Where the mat runs across the sheet.
        var mat: ClosedRange<CGFloat> = 396...840
        /// Anything the sheet itself has besides its layers, such as a layout grid.
        var dress: (@MainActor (inout Node) -> Void)?
        /// An artboard of its own to try it on, for what is done to a whole artboard: it lies
        /// beside the sheet where the mat would, and the sheet is only as wide as its words.
        var beside: (@MainActor () -> Node)?
        /// A note under the words, pointing across at the artboard beside them.
        var towards: String?
        /// The things to try, laid out on the mat whose frame it is given.
        var scene: @MainActor (CGRect) -> [Node] = { _ in [] }
    }

    /// A lesson's sheet: its words down the left, and its mat on the right with the things to try;
    /// or, for a lesson tried on an artboard of its own, the words alone and that artboard.
    /// Words that run long, as German ones do, make the sheet taller rather than crowd it.
    private static func sheet(_ lesson: Lesson, number: Int) -> (sheet: Node, beside: Node?) {
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
        if let other = lesson.beside?() {
            let edge = left * 2 + column
            var pointed: [Node] = []
            if let towards = lesson.towards {
                let hint = note(towards, at: CGPoint(x: left + 6, y: y + 10), tilt: -4)
                // Across to the sheet's edge, at the foot of the artboard beside it.
                let pointer = arrow(from: CGPoint(x: min(hint.frame.maxX + 8, edge - 60), y: hint.frame.midY + 2),
                                    to: CGPoint(x: edge - 12, y: hint.frame.minY - 14), bend: 12)
                pointed.append(pointing(hint, pointer))
                y = hint.frame.maxY + 16
            }
            let height = max(560, (y + 40).rounded(), other.frame.height)
            var board = Node(kind: .artboard, name: lesson.name(number), frame: CGRect(x: 0, y: 0, width: edge, height: height))
            board.children = [read(lesson.title, layers)] + pointed
            lesson.dress?(&board)
            return (board, other)
        }
        let height = max(560, (y + 40).rounded())
        let mat = CGRect(x: lesson.mat.lowerBound, y: 40, width: lesson.mat.upperBound - lesson.mat.lowerBound, height: height - 80)
        var board = Node(kind: .artboard, name: lesson.name(number), frame: CGRect(x: 0, y: 0, width: width, height: height))
        board.children = [backdrop(mat), read(lesson.title, layers)] + lesson.scene(mat)
        lesson.dress?(&board)
        return (board, nil)
    }

    // MARK: The lessons

    private static let moving = Lesson(
        name: { String(localized: "\($0). Move and turn") },
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
        name: { String(localized: "\($0). Corners and shadows") },
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

    private static let layering = Lesson(
        name: { String(localized: "\($0). Fills, borders, shadows") },
        title: String(localized: "Pile on the looks."),
        steps: [
            String(localized: "Click the button. Each of its fills, borders and shadows is a card of its own in the inspector, several of a kind in a pile."),
            String(localized: "Open a card and point at the + beside its ×: the button tries on another. Click to keep it."),
            String(localized: "Drag a card up or down its pile to lay it over or under the others."),
        ],
        tip: String(localized: "A shadow can fall inside a layer too, and grow all round with Spread."),
        scene: candy)

    /// A button as shiny as a sweet, made of two fills, two borders and three shadows.
    private static func candy(_ m: CGRect) -> [Node] {
        let f = CGRect(x: (m.midX - 150).rounded(), y: (m.midY - 64).rounded(), width: 300, height: 104)
        var button = shape(.rectangle, f, Ink.coral)
        button.name = String(localized: "Button")
        button.cornerRadius = 52
        let gloss = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: RGBA(r: 1, g: 1, b: 1, a: 0.5)), GradientStop(offset: 0.55, color: RGBA(r: 1, g: 1, b: 1, a: 0))],
                             start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1))
        button.fills = [Fill(color: Ink.coral), Fill(color: .white, gradient: gloss)]
        button.borders = [Border(on: true, color: RGBA(r: 1, g: 1, b: 1, a: 0.6), width: 3, position: .inside),
                          Border(on: true, color: Ink.ink, width: 3, position: .outside)]
        button.shadows = [
            Shadow(on: true, color: Ink.ink, x: 0, y: 9, blur: 0),
            Shadow(on: true, color: Ink.coral.with(alpha: 0.5), x: 0, y: 30, blur: 40, spread: -10),
            Shadow(on: true, color: RGBA(r: 0.5, g: 0.12, b: 0.05, a: 0.4), x: 0, y: -6, blur: 8, inset: true),
        ]
        var label = words("Bezzle", TextStyle(family: "Charter", face: "Bold Italic", size: 40), .white, at: .zero)
        label.frame.origin = CGPoint(x: (f.midX - label.frame.width / 2).rounded(), y: (f.midY - label.frame.height / 2 - 2).rounded())
        var hint = note(String(localized: "2 fills, 2 borders, 3 shadows"), at: CGPoint(x: 0, y: f.minY - 92), tilt: -4)
        hint.frame.origin.x = (f.midX - hint.frame.width / 2 + 10).rounded()
        let pointer = arrow(from: CGPoint(x: hint.frame.midX - 30, y: hint.frame.maxY + 4), to: CGPoint(x: f.midX - 54, y: f.minY - 10), bend: 14)
        return [button, label, pointing(hint, pointer)]
    }

    private static let typing = Lesson(
        name: { String(localized: "\($0). Text") },
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

    private static let styling = Lesson(
        name: { String(localized: "\($0). Styled text") },
        title: String(localized: "Mix styles in one text."),
        steps: [
            String(localized: "Double-click the recipe and drag across a few words to pick them. Change their colour, font or size in the inspector: only those letters change."),
            String(localized: "While typing, ⌘B, ⌘I and ⌘U make letters bold, italic or underlined, and ⇧⌘8 starts a list."),
            String(localized: "Press ⌘; to check the spelling. One word on the card is spelt wrong."),
        ],
        keys: ["⌘", "F"], tip: String(localized: "Finds and replaces words across every sheet."),
        scene: recipe)

    /// A recipe card whose words are styled in places: a word in colour, a list, a crossed-out line.
    private static func recipe(_ m: CGRect) -> [Node] {
        let o = CGPoint(x: (m.midX - 150).rounded(), y: (m.midY - 150).rounded())
        let inner: CGFloat = 244
        // On one line, smaller where the language makes one long word of it.
        let named = marked(String(localized: "*Lemon* cake", comment: "A recipe's title. The part between stars is set in colour and italic."),
                           starred: TextLook(face: "Bold Italic", color: Ink.coral))
        var title = Node(kind: .text, frame: .zero)
        for size in stride(from: CGFloat(34), through: 22, by: -2) {
            let style = TextStyle(family: "Charter", face: "Bold", size: size, lineSpacing: (size * 1.12).rounded())
            title = styled(named, style, Ink.ink, at: CGPoint(x: o.x + 28, y: o.y + 28), width: inner)
            if title.frame.height <= style.lineSpacing! + 1 { break }
        }
        let list = styled(marked(String(localized: "3 lemons\n200 g sugar\n~4 eggs~\na pinch of sallt",
                                        comment: "A recipe's list, one item a line. The line between ~ is crossed out. Keep exactly one word misspelt, as “sallt” is, for the reader to find with the spelling check."),
                                 starred: TextLook()).map { var r = $0; r.look.list = .bullet; return r },
                          TextStyle(size: 15, lineSpacing: 24), Ink.ink2, at: CGPoint(x: o.x + 28, y: title.frame.maxY + 16), width: inner)
        let method = styled(marked(String(localized: "Bake for *40 minutes* at 180 °C, then pour the *lemon syrup* over it while it’s warm.",
                                          comment: "A recipe's method. The parts between stars are set in bold."),
                                   starred: TextLook(face: "Bold")),
                            TextStyle(size: 15, lineSpacing: 22), Ink.ink2, at: CGPoint(x: o.x + 28, y: list.frame.maxY + 16), width: inner)
        var card = shape(.rectangle, CGRect(x: o.x, y: o.y, width: inner + 56, height: (method.frame.maxY + 30 - o.y).rounded()), RGBA(hex: "FFFDF8")!)
        card.cornerRadius = 14
        card.cornerSmoothing = 0.6
        card.shadow = Shadow(on: true, color: RGBA(r: 0.23, g: 0.2, b: 0.15, a: 0.14), x: 0, y: 10, blur: 28)
        card.locked = true
        let hint = note(String(localized: "double-click me"), at: CGPoint(x: o.x + 120, y: o.y - 52), tilt: -4)
        let pointer = arrow(from: CGPoint(x: hint.frame.minX - 6, y: hint.frame.midY + 4), to: CGPoint(x: o.x + 70, y: o.y + 18), bend: 16)
        return [card, title, list, method, pointing(hint, pointer)]
    }

    private static let painting = Lesson(
        name: { String(localized: "\($0). Gradients and pictures") },
        title: String(localized: "Paint with anything."),
        steps: [
            String(localized: "Click the word and open its Fill card. Click its colour, then Linear or Radial at the top of the menu: every letter takes the gradient. Drag the handles on the canvas to aim it."),
            String(localized: "Drop a photo from the Finder on the word. The photo shows through its letters, as it does in the word below, and they stay words you can type in."),
            String(localized: "Click the ring. Its Border card has the same choices: a gradient or a photo runs all the way round the border."),
        ],
        tip: String(localized: "Letters given a colour of their own while typing keep it over the paint."),
        scene: paints)

    /// A word to paint, a word the tour's photo shows through, and a ring whose border to paint.
    private static func paints(_ m: CGRect) -> [Node] {
        let heavy = TextStyle(family: "Charter", face: "Black", size: 84)
        var glow = words(String(localized: "Glow", comment: "A big word in the tour, there to be painted with a gradient."), heavy, Ink.coral,
                         at: CGPoint(x: m.minX + 44, y: m.minY + 74))
        glow.name = String(localized: "Words to paint")
        glow.locked = false
        var lake = words(String(localized: "Lake", comment: "A big word in the tour whose letters the tour's photo of a lake shows through."), heavy, Ink.navy,
                         at: CGPoint(x: m.minX + 44, y: glow.frame.maxY + 18))
        lake.name = String(localized: "Painted words")
        lake.fill.image = ImageFill(asset: photoAsset, mode: .cover, size: WelcomePhoto.size)
        lake.locked = false
        let side: CGFloat = 128
        var ring = shape(.ellipse, CGRect(x: m.maxX - 48 - side, y: m.maxY - 44 - side, width: side, height: side), Ink.sun)
        ring.name = String(localized: "Ring")
        ring.fill.on = false
        ring.border = Border(on: true, color: Ink.sun, width: 18, position: .inside)
        let paint = note(String(localized: "paint my letters"), at: CGPoint(x: m.minX + 150, y: m.minY + 26), tilt: -4)
        let toGlow = arrow(from: CGPoint(x: paint.frame.minX - 6, y: paint.frame.midY + 4), to: CGPoint(x: m.minX + 96, y: glow.frame.minY + 14), bend: 14)
        var border = note(String(localized: "and my border"), at: CGPoint(x: 0, y: ring.frame.minY - 50), tilt: -5)
        border.frame.origin.x = (min(ring.frame.midX - border.frame.width / 2, m.maxX - 18 - border.frame.width)).rounded()
        let toRing = arrow(from: CGPoint(x: border.frame.minX + 24, y: border.frame.maxY + 4), to: CGPoint(x: ring.frame.minX + 14, y: ring.frame.minY + 20), bend: 16)
        return [glow, lake, ring, pointing(paint, toGlow), pointing(border, toRing)]
    }

    private static let drawing = Lesson(
        name: { String(localized: "\($0). Pen") },
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
        name: { String(localized: "\($0). Knife and pieces") },
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
        name: { String(localized: "\($0). Repeat grid") },
        title: String(localized: "One card, a whole list."),
        steps: [
            String(localized: "Click the card and press ⌘R. It becomes a repeat grid."),
            String(localized: "Pull the blue handle on its bottom edge downward. Every new card is a copy."),
            String(localized: "Change one card, its colour or its size, and they all follow. The words in each stay their own."),
        ],
        tip: String(localized: "Drop a folder of photos or a text file on a grid to fill every card at once."),
        scene: card)

    private static let linking = Lesson(
        name: { String(localized: "\($0). Components") },
        title: String(localized: "Change one, change them all."),
        steps: [
            String(localized: "These three buttons are copies of one component. Click one, then click its shape and give it another colour. The others take it as the light reaches them."),
            String(localized: "Double-click a label and type. The words are each copy's own, and its button grows round them."),
            String(localized: "Change a colour again and click New Variant in the word that comes up. The variants lie beside a selected button, to switch between."),
        ],
        keys: ["⌥", "⌘", "K"],
        tip: String(localized: "Select anything and press these keys to make it a component. Parts from the resources panel are components already: drop one twice and both change together."),
        scene: buttons)

    /// The buttons of the lesson on components, made one component when the tour is put together.
    private static let buttonIDs = [
        UUID(uuidString: "6B1D2C9E-5A41-4C7E-9B0E-3F2A1D8C7E01")!,
        UUID(uuidString: "6B1D2C9E-5A41-4C7E-9B0E-3F2A1D8C7E02")!,
        UUID(uuidString: "6B1D2C9E-5A41-4C7E-9B0E-3F2A1D8C7E03")!,
    ]

    private static func buttons(_ m: CGRect) -> [Node] {
        let labels = [String(localized: "Continue"), String(localized: "Save"), String(localized: "Share")]
        let x = m.minX + 96
        var made: [Node] = []
        for (i, label) in labels.enumerated() {
            let y = m.minY + 120 + CGFloat(i) * 76
            var text = words(label, TextStyle(face: "Semibold", size: 16, align: .center), RGBA.white, at: .zero)
            let w = max(140, (text.frame.width + 64).rounded())
            var pill = shape(.rectangle, CGRect(x: x, y: y, width: w, height: 48), Ink.pencil)
            pill.cornerRadius = 24
            pill.shadow = Shadow(on: true, color: RGBA(r: 0.2, g: 0.27, b: 0.6, a: 0.22), x: 0, y: 6, blur: 14)
            text.frame.origin = CGPoint(x: (pill.frame.midX - text.frame.width / 2).rounded(), y: (pill.frame.midY - text.frame.height / 2).rounded())
            var button = group(String(localized: "Pill button"), [pill, text].map { var n = $0; n.locked = false; return n })
            button.id = buttonIDs[i]
            made.append(button)
        }
        let hint = note(String(localized: "change one"), at: CGPoint(x: x + 210, y: m.minY + 84), tilt: -4)
        let pointer = arrow(from: CGPoint(x: hint.frame.minX - 6, y: hint.frame.midY + 4), to: CGPoint(x: x + 150, y: m.minY + 126), bend: 14)
        return made + [pointing(hint, pointer)]
    }

    private static let naming = Lesson(
        name: { String(localized: "\($0). Styles") },
        title: String(localized: "Give a look a name."),
        steps: [
            String(localized: "Click the button and open its Fill card. Click + Style, then press ↩ to keep the name Bezzle offers."),
            String(localized: "Two more layers have the same colour, so Bezzle offers to name them too: click Name Them Too. Now change the colour and watch it run over all three."),
            String(localized: "Click an empty spot on the canvas. The design’s styles are at the top of the inspector: change one there, and every layer that has it follows."),
        ],
        tip: String(localized: "Type, shadows and corners can have names too. Looks that several layers share wait among the styles, dashed: one click names them all."),
        scene: studio)

    /// The colours of the card in the lesson on styles, its own: naming one names every layer of
    /// the tour that has it.
    private enum Studio {
        static let teal = RGBA(hex: "1E9E8A")!
        static let card = RGBA(hex: "FFFCF7")!
        static let ink = RGBA(hex: "26302E")!
        static let ink2 = RGBA(hex: "5F6B68")!
        static let paper = RGBA(hex: "F7FFFC")!
    }

    /// A card for an open day, its colour on a tag, a rule and a button, without a name yet. Its
    /// words stay put, so a click on them goes to what they lie on.
    private static func studio(_ m: CGRect) -> [Node] {
        let o = CGPoint(x: (m.midX - 150).rounded(), y: (m.midY - 168).rounded())
        let inner: CGFloat = 244
        var day = words(String(localized: "Saturday"), TextStyle(face: "Semibold", size: 11, tracking: 120, letterCase: .upper), Studio.paper, at: .zero)
        var tag = shape(.rectangle, CGRect(x: o.x + 28, y: o.y + 30, width: (day.frame.width + 24).rounded(), height: 24), Studio.teal)
        tag.name = String(localized: "Tag")
        tag.cornerRadius = 12
        day.frame.origin = CGPoint(x: (tag.frame.midX - day.frame.width / 2).rounded(), y: (tag.frame.midY - day.frame.height / 2).rounded())
        let title = words(String(localized: "Open studio"), TextStyle(family: "Charter", face: "Bold", size: 30, lineSpacing: 34), Studio.ink,
                          at: CGPoint(x: o.x + 28, y: tag.frame.maxY + 16), width: inner)
        var rule = shape(.rectangle, CGRect(x: o.x + 28, y: title.frame.maxY + 12, width: 36, height: 4), Studio.teal)
        rule.name = String(localized: "Rule")
        rule.cornerRadius = 2
        let body = words(String(localized: "Paint, print and throw pots with us, from ten till four."), TextStyle(size: 14, lineSpacing: 21), Studio.ink2,
                         at: CGPoint(x: o.x + 28, y: rule.frame.maxY + 14), width: inner)
        var label = words(String(localized: "Join us"), TextStyle(face: "Semibold", size: 15), Studio.paper, at: .zero)
        var button = shape(.rectangle, CGRect(x: o.x + 28, y: body.frame.maxY + 22, width: max(124, label.frame.width + 48).rounded(), height: 44), Studio.teal)
        button.name = String(localized: "Join button")
        button.cornerRadius = 22
        label.frame.origin = CGPoint(x: (button.frame.midX - label.frame.width / 2).rounded(), y: (button.frame.midY - label.frame.height / 2).rounded())
        var card = shape(.rectangle, CGRect(x: o.x, y: o.y, width: inner + 56, height: (button.frame.maxY + 30 - o.y).rounded()), Studio.card)
        card.name = String(localized: "Event card")
        card.cornerRadius = 18
        card.cornerSmoothing = 0.6
        card.shadow = Shadow(on: true, color: RGBA(r: 0.12, g: 0.24, b: 0.2, a: 0.14), x: 0, y: 12, blur: 30)
        // Its right end kept on the mat, however long the words.
        var hint = note(String(localized: "name my colour"), at: CGPoint(x: 0, y: card.frame.maxY + 26), tilt: -4)
        hint.frame.origin.x = (min(button.frame.maxX + 40, m.maxX - 18 - hint.frame.width)).rounded()
        let pointer = arrow(from: CGPoint(x: hint.frame.minX - 6, y: hint.frame.midY - 2), to: CGPoint(x: button.frame.maxX - 18, y: button.frame.maxY + 8), bend: -14)
        return [card, tag, day, title, rule, body, button, label, pointing(hint, pointer)]
    }

    private static let darkening = Lesson(
        name: { String(localized: "\($0). Light and dark") },
        title: String(localized: "Turn the lights down."),
        steps: [
            String(localized: "Click the name above the weather screen’s corner. Point at Dark at the foot of the inspector: the screen shows how it looks at night. Click to keep it."),
            String(localized: "Each of its colours now has a name and a dark look, made for you. Change one on the dark screen, and only its dark look changes."),
            String(localized: "Open its Dark card and click Light One Beside It. The sun and moon on the card switch the screen between the two."),
        ],
        tip: String(localized: "With nothing selected, the styles show each colour’s light and dark looks side by side."),
        beside: weather,
        towards: String(localized: "try it on this screen"))

    /// The colours of the weather screen, its own and found nowhere else in the tour: shown dark,
    /// the screen names every colour it has, and so would the same colours on every other sheet.
    private enum Sky {
        static let ground = RGBA(hex: "EAF1FA")!
        static let card = RGBA(hex: "FAFCFF")!
        static let ink = RGBA(hex: "142033")!
        static let ink2 = RGBA(hex: "5B6B80")!
        static let sun = RGBA(hex: "FFB21F")!
        static let blue = RGBA(hex: "2F6FE4")!
        static let paper = RGBA(hex: "FBFDFF")!
    }

    /// A weather app's screen, light, to turn dark. One colour each, no gradients: a light colour
    /// in a gradient goes dark in the dark as a ground does, and a sun would turn black inside.
    private static func weather() -> Node {
        let w: CGFloat = 360, h: CGFloat = 548, x: CGFloat = 32
        let today = words(String(localized: "Today"), TextStyle(face: "Semibold", size: 11, tracking: 140, letterCase: .upper), Sky.ink2, at: CGPoint(x: x, y: 44))
        let sky = words(String(localized: "Sunny spells"), TextStyle(family: "Charter", face: "Bold", size: 30, lineSpacing: 34), Sky.ink,
                        at: CGPoint(x: x, y: today.frame.maxY + 8), width: 180)
        let degrees = words("21°", TextStyle(face: "Light", size: 96), Sky.ink, at: CGPoint(x: x - 5, y: sky.frame.maxY + 6))
        let wind = words(String(localized: "A light breeze, no rain."), TextStyle(size: 15, lineSpacing: 22), Sky.ink2, at: CGPoint(x: x, y: degrees.frame.maxY + 2))
        var sun = shape(.ellipse, CGRect(x: w - x - 104, y: sky.frame.maxY + 18, width: 104, height: 104), Sky.sun)
        sun.shadow = Shadow(on: true, color: Sky.sun.with(alpha: 0.5), x: 0, y: 10, blur: 36)
        var layers = [today, sky, degrees, wind, sun]
        let top = wind.frame.maxY + 30, side = ((w - x * 2 - 24) / 3).rounded(.down)
        for (i, (time, temperature)) in [("9:00", "17°"), ("12:00", "21°"), ("15:00", "19°")].enumerated() {
            let f = CGRect(x: x + CGFloat(i) * (side + 12), y: top, width: side, height: 104)
            var card = shape(.rectangle, f, Sky.card)
            card.cornerRadius = 16
            card.cornerSmoothing = 0.6
            card.shadow = Shadow(on: true, color: RGBA(r: 0.08, g: 0.13, b: 0.2, a: 0.08), x: 0, y: 4, blur: 12)
            var hour = words(time, TextStyle(face: "Medium", size: 12), Sky.ink2, at: .zero)
            hour.frame.origin = CGPoint(x: (f.midX - hour.frame.width / 2).rounded(), y: f.minY + 16)
            let dot = shape(.ellipse, CGRect(x: f.midX - 8, y: f.minY + 40, width: 16, height: 16), Sky.sun)
            var warm = words(temperature, TextStyle(face: "Semibold", size: 20), Sky.ink, at: .zero)
            warm.frame.origin = CGPoint(x: (f.midX - warm.frame.width / 2).rounded(), y: f.minY + 64)
            layers.append(group(time, [card, hour, dot, warm].map { var n = $0; n.locked = false; return n }))
        }
        var label = words(String(localized: "Next 7 days"), TextStyle(face: "Semibold", size: 15), Sky.paper, at: .zero)
        // At the foot of the screen, as an app has it.
        var button = shape(.rectangle, CGRect(x: x, y: h - 36 - 48, width: w - x * 2, height: 48), Sky.blue)
        button.cornerRadius = 24
        label.frame.origin = CGPoint(x: (button.frame.midX - label.frame.width / 2).rounded(), y: (button.frame.midY - label.frame.height / 2).rounded())
        layers += [button, label]
        var board = Node(kind: .artboard, name: String(localized: "Weather"), frame: CGRect(x: 0, y: 0, width: w, height: h))
        board.fill.color = Sky.ground
        board.children = layers.map { var n = $0; n.locked = false; return n }
        return board
    }

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
            String(localized: "or pick one in the row below"),
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

        var board = Node(kind: .artboard, name: String(localized: "\(number). Stacks"), frame: CGRect(x: 0, y: 0, width: width, height: height))
        board.children = [panel, figure, kicker, title, body, hint, pointer]
        return (board, [(title.id, titles), (body.id, bodies), (hint.id, hints), (figure.id, digits)])
    }

    /// Where the blocks to line up have their tops, more or less.
    private static let blockTop: CGFloat = 150

    private static let lining = Lesson(
        name: { String(localized: "\($0). Rulers and grids") },
        title: String(localized: "Line it all up."),
        steps: [
            String(localized: "Drag from the ruler at the top or left onto the sheet to pull out a guide. Drag it back onto the ruler to put it away."),
            String(localized: "This sheet has a layout grid. Move a block: the columns light up and the block catches on their edges."),
            String(localized: "Click the sheet’s name above its corner, then drag sideways across its Layout Grid card in the inspector to change the number of columns."),
        ],
        keys: ["⌃", "R"], tip: String(localized: "Shows or hides the rulers. ⌃, does the same for guides, ⌃G for layout grids."),
        // The mat lies on the grid's columns 6 to 12.
        mat: 386...824,
        // No guide yet: one across the sheet would run through the words. The first step pulls one out.
        dress: { $0.layout = LayoutGrid(columns: LayoutGrid.Track(count: 12, gutter: 24, margin: 56), rows: nil, baseline: nil) },
        scene: blocks)

    /// Blocks laid out by eye, each a little off the columns they are meant to fill.
    private static func blocks(_ m: CGRect) -> [Node] {
        // Columns of 42 with gutters of 24, from 56 in.
        func column(_ i: Int) -> CGFloat { 56 + CGFloat(i - 1) * 66 }
        func block(_ name: String, _ from: Int, _ to: Int, y: CGFloat, height: CGFloat, off: CGFloat, _ colour: RGBA) -> Node {
            var n = shape(.rectangle, CGRect(x: column(from) + off, y: y, width: column(to) + 42 - column(from), height: height), colour)
            n.name = name
            n.cornerRadius = 10
            return n
        }
        let name = String(localized: "Block")
        let picture = block(name, 7, 9, y: blockTop + 7, height: 150, off: 9, Ink.coral)
        let side = block(name, 10, 11, y: blockTop - 5, height: 150, off: -6, Ink.sun)
        let wide = block(name, 7, 11, y: blockTop + 182, height: 64, off: 12, Ink.navy)
        let small = block(name, 7, 8, y: blockTop + 268, height: 40, off: -8, Ink.sage)
        var hint = note(String(localized: "snap us to the columns"), at: CGPoint(x: 0, y: m.minY + 34), tilt: -4)
        hint.frame.origin.x = (m.maxX - 30 - hint.frame.width).rounded()
        let pointer = arrow(from: CGPoint(x: hint.frame.minX - 6, y: hint.frame.midY + 6), to: CGPoint(x: picture.frame.minX + 30, y: picture.frame.minY - 12), bend: 18)
        return [picture, side, wide, small, pointing(hint, pointer)]
    }

    private static let adapting = Lesson(
        name: { String(localized: "\($0). Adaptive layout") },
        title: String(localized: "One design, every size."),
        steps: [
            String(localized: "Click the name above the flyer’s corner and drag its right edge out. Bezzle lays the design out again as it grows: given room, the photo moves beside the words."),
            String(localized: "Open its Artboard card and point at the sizes in its Size menu: the flyer tries each one on. Click one, and its layers spring into their new places."),
            String(localized: "Press ⌘Z to go back: the design is just as it was. Turn off Adapt layout in the same card to resize an artboard without moving anything."),
        ],
        beside: flyer,
        towards: String(localized: "try it on this flyer"))

    /// The colours of the flyer, apart from every other sheet's.
    private enum Lakeside {
        static let ground = RGBA(hex: "FFF6EA")!
        static let ink = RGBA(hex: "22313A")!
        static let ink2 = RGBA(hex: "56656C")!
        static let accent = RGBA(hex: "DE5A40")!
        static let paper = RGBA(hex: "FFFCF5")!
    }

    /// A flyer for an evening by the lake: the tour's photo across its top, words and a button under it.
    private static func flyer() -> Node {
        let w: CGFloat = 380, h: CGFloat = 475, x: CGFloat = 32
        let picture = photo(CGRect(x: 0, y: 0, width: w, height: 216))
        let when = words(String(localized: "Saturday, 6 pm"), TextStyle(face: "Semibold", size: 11, tracking: 140, letterCase: .upper), Lakeside.accent,
                         at: CGPoint(x: x, y: picture.frame.maxY + 30))
        let title = words(String(localized: "Summer by the lake"), TextStyle(family: "Charter", face: "Bold", size: 32, lineSpacing: 36), Lakeside.ink,
                          at: CGPoint(x: x, y: when.frame.maxY + 8), width: w - x * 2)
        let body = words(String(localized: "Swim, picnic and stay for the sunset. Bring a friend."), TextStyle(size: 15, lineSpacing: 22), Lakeside.ink2,
                         at: CGPoint(x: x, y: title.frame.maxY + 10), width: w - x * 2)
        var label = words(String(localized: "Count me in"), TextStyle(face: "Semibold", size: 15), Lakeside.paper, at: .zero)
        var button = shape(.rectangle, CGRect(x: x, y: body.frame.maxY + 24, width: max(140, label.frame.width + 48).rounded(), height: 44), Lakeside.accent)
        button.cornerRadius = 22
        label.frame.origin = CGPoint(x: (button.frame.midX - label.frame.width / 2).rounded(), y: (button.frame.midY - label.frame.height / 2).rounded())
        var board = Node(kind: .artboard, name: String(localized: "Flyer"), frame: CGRect(x: 0, y: 0, width: w, height: max(h, (button.frame.maxY + 32).rounded())))
        board.fill.color = Lakeside.ground
        board.children = [picture, when, title, body, button, label].map { var n = $0; n.locked = false; return n }
        return board
    }

    private static let tipping = Lesson(
        name: { String(localized: "\($0). 3D") },
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
        name: { String(localized: "\($0). Remove background") },
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

    private static let developing = Lesson(
        name: { String(localized: "\($0). Photo editing") },
        title: String(localized: "Bring out the light."),
        steps: [
            String(localized: "Click the photo and drag sideways across its Photo card in the inspector. Bezzle develops it as suits it best, as strongly as you like."),
            String(localized: "Open the card, then drag up or down on the photo itself: the tones under the pointer grow lighter or darker. Under Colour, the same drag changes the colour under it."),
            String(localized: "Hold the compare button to see the original. It is always kept: × takes the photo back to it."),
        ],
        tip: String(localized: "Under Colour, click something white or grey to make it neutral."),
        scene: lake)

    private static func lake(_ m: CGRect) -> [Node] {
        let f = CGRect(x: (m.midX - 186).rounded(), y: (m.midY - 112).rounded(), width: 372, height: 248)
        var framed = photo(f)
        framed.border = Border(on: true, color: .white, width: 10, position: .inside)
        framed.shadow = Shadow(on: true, color: RGBA(r: 0.23, g: 0.2, b: 0.15, a: 0.2), x: 0, y: 12, blur: 30)
        let hint = note(String(localized: "a little flat, isn’t it?"), at: CGPoint(x: f.minX + 8, y: f.maxY + 30), tilt: -3)
        let pointer = arrow(from: CGPoint(x: hint.frame.maxX + 8, y: hint.frame.midY), to: CGPoint(x: f.midX + 70, y: f.maxY + 8), bend: 18)
        return [framed, pointing(hint, pointer)]
    }

    private static let curving = Lesson(
        name: { String(localized: "\($0). Curves") },
        title: String(localized: "Bend the words."),
        steps: [
            String(localized: "Click the headline. Swing a bead at one of its ends down and round: the words bend after it, and straight below they close into a ring."),
            String(localized: "Drag the label onto the edge of the badge and hold it still. After a moment the words jump onto it. Keep dragging to slide them round, to either side."),
            String(localized: "Resize the badge or drag its points: the words follow. Pull them well clear of it to take them off."),
        ],
        tip: String(localized: "Double-click words on a curve to type: they straighten while you do."),
        scene: badge)

    /// Words to bend, a badge to lay words round, and the words to lay round it.
    private static func badge(_ m: CGRect) -> [Node] {
        var headline = words(String(localized: "Make it bend"), TextStyle(family: "Charter", face: "Bold", size: 40), Ink.coral,
                             at: CGPoint(x: m.minX + 48, y: m.minY + 60))
        headline.name = String(localized: "Words to bend")
        headline.locked = false
        var label = words(String(localized: "Fresh from the oven"), TextStyle(face: "Semibold", size: 15, tracking: 120, letterCase: .upper), Ink.ink,
                          at: CGPoint(x: m.minX + 48, y: m.minY + 230))
        label.name = String(localized: "Label")
        label.locked = false
        let side: CGFloat = 170
        var disc = shape(.ellipse, CGRect(x: m.maxX - 64 - side, y: max(m.maxY - 56 - side, label.frame.maxY + 90), width: side, height: side), Ink.sun)
        disc.name = String(localized: "Badge")
        disc.shadow = Shadow(on: true, color: RGBA(r: 0.35, g: 0.24, b: 0.05, a: 0.22), x: 0, y: 10, blur: 22)
        // The bead shows a little past the headline's end, on its baseline.
        let bead = note(String(localized: "swing my end"), at: CGPoint(x: headline.frame.maxX - 70, y: headline.frame.maxY + 34), tilt: -5)
        let toBead = arrow(from: CGPoint(x: bead.frame.maxX - 30, y: bead.frame.minY - 4), to: CGPoint(x: headline.frame.maxX + 20, y: headline.frame.maxY - 8), bend: -14)
        let edge = note(String(localized: "hold me on its edge"), at: CGPoint(x: m.minX + 44, y: label.frame.maxY + 22), tilt: -4)
        let toEdge = arrow(from: CGPoint(x: edge.frame.midX, y: edge.frame.maxY + 6), to: CGPoint(x: disc.frame.minX - 8, y: disc.frame.midY), bend: -26)
        return [disc, headline, label, pointing(bead, toBead), pointing(edge, toEdge)]
    }

    private static let framing = Lesson(
        name: { String(localized: "\($0). Masks") },
        title: String(localized: "Put it in a shape."),
        steps: [
            String(localized: "Drag the photo over the arch and hold it still. After a moment the arch opens and takes the photo in."),
            String(localized: "Keep dragging to frame it, then let go. Drag it all the way out again to take it back out."),
            String(localized: "Or select a shape and what should go in it, and click Mask above them."),
        ],
        keys: ["⌃", "⌘", "M"], tip: String(localized: "Masks what is selected. ↩ reaches into a mask."),
        scene: arch)

    /// An arch and a round window to hold a photo, and the photo lying apart.
    private static func arch(_ m: CGRect) -> [Node] {
        let a = CGRect(x: m.maxX - 64 - 156, y: m.minY + 40, width: 156, height: 208)
        let r = a.width / 2, k = r * 0.5523
        var outline = Trace()
        outline.move(a.minX, a.maxY)
        outline.line(a.minX, a.minY + r)
        outline.curve(a.minX, a.minY + r - k, a.midX - k, a.minY, a.midX, a.minY)
        outline.curve(a.midX + k, a.minY, a.maxX, a.minY + r - k, a.maxX, a.minY + r)
        outline.line(a.maxX, a.maxY)
        outline.close()
        var window = path(outline, fill: RGBA(hex: "E6DFD2")!)
        window.name = String(localized: "Arch")
        window.border = Border(on: true, color: .white, width: 10, position: .inside)
        window.shadow = Shadow(on: true, color: RGBA(r: 0.23, g: 0.2, b: 0.15, a: 0.2), x: 0, y: 10, blur: 24)
        var round = shape(.ellipse, CGRect(x: m.maxX - 64 - 112, y: m.maxY - 44 - 112, width: 112, height: 112), RGBA(hex: "E6DFD2")!)
        round.name = String(localized: "Circle")
        round.border = Border(on: true, color: .white, width: 8, position: .inside)
        round.shadow = window.shadow
        let p = photo(CGRect(x: m.minX + 34, y: m.maxY - 44 - 140, width: 210, height: 140))
        let hint = note(String(localized: "hold me over the arch"), at: CGPoint(x: m.minX + 28, y: p.frame.minY - 54), tilt: -4)
        // Up from the note, round to the arch's side.
        let pointer = arrow(from: CGPoint(x: hint.frame.minX + 40, y: hint.frame.minY - 6), to: CGPoint(x: a.minX - 12, y: a.minY + 70), bend: -30)
        return [window, round, p, pointing(hint, pointer)]
    }

    private static let marking = Lesson(
        name: { String(localized: "\($0). Export sizes") },
        title: String(localized: "Every size at once."),
        steps: [
            String(localized: "Click the icon. Its Export card in the inspector lists the sizes it is saved at: 1×, 2× and 3×, each file named to match."),
            String(localized: "Open the card and click + for another size, or type 512w for a width in pixels. Each size can be PNG, JPEG, WebP, AVIF, SVG or PDF."),
            String(localized: "Select the sticker and click Export at the foot of the inspector to mark it too. Then press ⌘E and choose 2 marked."),
        ],
        scene: icons)

    /// An app icon marked for export in three sizes, and a sticker not marked yet.
    private static func icons(_ m: CGRect) -> [Node] {
        let f = CGRect(x: m.minX + 70, y: (m.midY - 100).rounded(), width: 164, height: 164)
        var tile = shape(.rectangle, f, Ink.pencil)
        tile.cornerRadius = 38
        tile.cornerSmoothing = 0.6
        tile.fill.gradient = linear(RGBA(hex: "4E7BEA")!, RGBA(hex: "7B5CF0")!, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1))
        tile.shadow = Shadow(on: true, color: RGBA(r: 0.13, g: 0.12, b: 0.3, a: 0.28), x: 0, y: 12, blur: 26)
        let sun = shape(.ellipse, CGRect(x: f.minX + 92, y: f.minY + 38, width: 34, height: 34), RGBA(hex: "FFD66B")!)
        var hills = Trace()
        hills.move(f.minX + 26, f.maxY - 36)
        hills.line(f.minX + 66, f.minY + 72)
        hills.line(f.minX + 92, f.minY + 104)
        hills.line(f.minX + 108, f.minY + 90)
        hills.line(f.maxX - 26, f.maxY - 36)
        hills.close()
        var icon = group(String(localized: "App icon"), [tile, sun, path(hills, fill: .white)])
        icon.exports = [ExportPreset(size: .scale(1)), ExportPreset(size: .scale(2)), ExportPreset(size: .scale(3))]

        let c = CGPoint(x: m.maxX - 120, y: f.midY + 6)
        var star = Trace()
        for i in 0..<16 {
            let angle = (-90 + Double(i) * 22.5) * .pi / 180, r: CGFloat = i % 2 == 0 ? 74 : 60
            let p = CGPoint(x: c.x + r * CGFloat(cos(angle)), y: c.y + r * CGFloat(sin(angle)))
            if i == 0 { star.move(p.x, p.y) } else { star.line(p.x, p.y) }
        }
        star.close()
        var sticker = path(star, fill: Ink.sun)
        sticker.name = String(localized: "Sticker")
        sticker.rotation = 12
        sticker.shadow = Shadow(on: true, color: RGBA(hex: "F5A524", alpha: 0.4)!, x: 0, y: 8, blur: 18)

        let marked = note(String(localized: "marked: 1×, 2×, 3×"), at: CGPoint(x: f.minX - 4, y: f.maxY + 34), tilt: -3)
        var mark = note(String(localized: "mark me too"), at: CGPoint(x: 0, y: c.y - 140), tilt: -5)
        mark.frame.origin.x = (min(c.x - mark.frame.width / 2, m.maxX - 24 - mark.frame.width)).rounded()
        return [icon, sticker, marked, mark]
    }

    private static let sharing = Lesson(
        name: { String(localized: "\($0). Share and export") },
        title: String(localized: "Send it out into the world."),
        steps: [
            String(localized: "Press ⌘E to export an artboard, a layer or every post of a stack as PNG, JPEG, WebP, AVIF, SVG or PDF."),
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

    /// The photo the tour brings (`WelcomePhoto`), as it is named in the design's images.
    static let photoAsset = "welcome-lake.jpg"

    /// The tour's photo, filling a rectangle.
    private static func photo(_ frame: CGRect) -> Node {
        var n = shape(.rectangle, frame, .white)
        n.name = String(localized: "Photo")
        n.fill.image = ImageFill(asset: photoAsset, mode: .cover, size: WelcomePhoto.size)
        return n
    }

    /// Words some of which are marked out: those between stars look as `starred` says, those
    /// between tildes are crossed out. As runs, to make into one layer.
    private static func marked(_ text: String, starred: TextLook) -> [TextSpan] {
        var runs: [TextSpan] = [], words = "", look = TextLook()
        for letter in text {
            guard letter == "*" || letter == "~" else {
                words.append(letter)
                continue
            }
            if !words.isEmpty { runs.append(TextSpan(text: words, look: look)) }
            words = ""
            let marking = letter == "*" ? starred : TextLook(strikethrough: true)
            look = look == marking ? TextLook() : marking
        }
        if !words.isEmpty { runs.append(TextSpan(text: words, look: look)) }
        return runs
    }

    /// Words styled in places, free to change: wrapped to `width`.
    private static func styled(_ runs: [TextSpan], _ style: TextStyle, _ colour: RGBA, at p: CGPoint, width: CGFloat) -> Node {
        var n = words(runs.map(\.text).joined(), style, colour, at: p, width: width)
        n.setRuns(runs)
        n.locked = false
        n.refit()
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
