import Foundation
import CoreGraphics

// What an export makes, shared by every Bezzle: the things that go out (artboards, slides,
// posts, layers), the files they become, what they are called and where they go, and what the
// Export sheet offers and says. Drawing them and writing the files is each platform's own
// (Exporter.swift on the Mac, the Windows core's Exporting.swift).

/// One thing to export: an artboard, one slide of a carousel, or one layer on its own, from
/// wherever it lies. Drawn on any thread, so that exporting can go on beside the canvas.
nonisolated struct ExportItem: Sendable {
    /// Which slide of how many, and where it lies in the carousel, in the carousel's own coordinates.
    struct Slide {
        let number: Int
        let count: Int
        let rect: CGRect
    }

    let node: Node
    /// The artboard a layer lies on, for what shows through its background blurs.
    let board: Node?
    /// Where the top left of what holds the layer is, on the canvas.
    let origin: CGPoint
    /// Set when the artboard is a carousel and this is one of its slides.
    let slide: Slide?
    /// Set when the artboard is one post of a deck: which, of how many, and what it says first,
    /// so that the files are told apart by more than their numbers.
    var post: (number: Int, count: Int, words: String?)?

    init(artboard: Node) {
        node = artboard
        board = nil
        origin = .zero
        slide = nil
    }

    /// The slide `number` of a carousel, counted from 1.
    init(slide number: Int, of carousel: Node) {
        let rects = carousel.slideRects
        node = carousel
        board = nil
        origin = .zero
        slide = Slide(number: number, count: rects.count, rect: rects[min(max(number, 1), rects.count) - 1])
    }

    init?(layer id: UUID, in doc: BezzleDocument) {
        guard let n = doc.node(id), !n.isArtboard, !n.hidden else { return nil }
        node = n
        // On a deck, what lies behind it is its own post, not the deck's first.
        board = doc.post(of: id).map { $0.deck.showing($0.post) } ?? doc.artboard(of: id)
        origin = doc.parentOrigin(of: id)
        slide = nil
    }

    /// What an artboard goes out as: a deck a post at a time, a carousel a slide at a time, and
    /// anything else whole.
    static func items(for artboard: Node) -> [ExportItem] {
        if artboard.isDeck {
            let posts = artboard.posts
            return posts.enumerated().flatMap { i, p in
                let shown = artboard.showing(p)
                return items(for: shown).map { item in
                    var each = item
                    each.post = (i + 1, posts.count, headline(of: shown))
                    return each
                }
            }
        }
        guard artboard.isCarousel else { return [ExportItem(artboard: artboard)] }
        return (1...artboard.slideCount).map { ExportItem(slide: $0, of: artboard) }
    }

    /// What these artboards and layers go out as: an artboard as `items(for:)` says, and any
    /// other layer on its own. Hidden ones are left out.
    static func items(for ids: [UUID], in doc: BezzleDocument) -> [ExportItem] {
        ids.flatMap { id -> [ExportItem] in
            guard let n = doc.node(id) else { return [] }
            if n.isArtboard { return n.hidden ? [] : items(for: n) }
            return ExportItem(layer: id, in: doc).map { [$0] } ?? []
        }
    }

    /// Everything marked for export that shows, top to bottom of the layers list: each artboard
    /// whole, as `items(for:)` says, and each layer on its own, on a deck those of the post in
    /// front. `seen` is the design as it is seen (`DocumentStore.seenDoc`).
    static func marked(in doc: BezzleDocument, seen: BezzleDocument) -> [ExportItem] {
        var out: [ExportItem] = []
        func visit(_ n: Node) {
            guard !n.hidden else { return }
            if n.exports?.isEmpty == false {
                if n.isArtboard {
                    // The deck itself, with every post, not only the one in front.
                    if let board = doc.node(n.id) { out += items(for: board) }
                } else if let item = ExportItem(layer: n.id, in: seen) {
                    out.append(item)
                }
            }
            n.children.forEach(visit)
        }
        seen.nodes.forEach(visit)
        return out
    }

    /// What one post of a deck goes out as: the post, as it is numbered among the others.
    static func items(for deck: Node, post: Int?) -> [ExportItem] {
        let posts = deck.posts
        guard deck.isDeck, let post, let i = posts.firstIndex(of: post) else { return items(for: deck) }
        let shown = deck.showing(post)
        return items(for: shown).map { item in
            var each = item
            each.post = (i + 1, posts.count, headline(of: shown))
            return each
        }
    }

    /// What a post says first: the words set largest on it, a line of them, short enough for a name.
    private static func headline(of board: Node) -> String? {
        var best: (size: CGFloat, text: String)?
        func visit(_ n: Node) {
            if n.kind == .text, !n.hidden, let text = n.text, let size = n.style?.size, size > (best?.size ?? 0) {
                let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                if !line.isEmpty { best = (size, line) }
            }
            if !n.hidden { n.children.forEach(visit) }
        }
        board.children.forEach(visit)
        guard var words = best?.text else { return nil }
        words = String(words.map { "/:\\".contains($0) ? "-" : $0 })
        return words.count > 40 ? String(words.prefix(40)).trimmingCharacters(in: .whitespaces) + "…" : words
    }

    /// A number with as many digits as the last one has and at least two, so files sort in order.
    private static func padded(_ number: Int, of count: Int) -> String {
        let digits = max(2, String(count).count), n = String(number)
        return String(repeating: "0", count: max(0, digits - n.count)) + n
    }

    /// A slide's carries its number, so that the files sort in order: "Launch 01", "Launch 02"…;
    /// a post's its number and what it says first: "Sale 03 Hats".
    var name: String {
        var name = node.name
        if let post {
            name += " \(Self.padded(post.number, of: post.count))"
            if let words = post.words { name += " \(words)" }
        }
        guard let slide else { return name }
        return "\(name) \(Self.padded(slide.number, of: slide.count))"
    }

    /// The part of the canvas a slide covers.
    var slideFrame: CGRect? { slide.map { $0.rect.offsetBy(dx: node.frame.minX, dy: node.frame.minY) } }

    /// What it is drawn with: for a layer, where it sits on its artboard, so that a blur of what
    /// lies behind it finds that.
    func options(scale: CGFloat, assets: Assets?) -> Renderer.Options {
        var o = Renderer.Options(deviceScale: scale, assets: assets)
        if let board {
            o.board = board
            o.offset = CGPoint(x: origin.x - board.frame.minX, y: origin.y - board.frame.minY)
        }
        return o
    }

    /// Draws a layer as it is on the canvas, the context in canvas coordinates.
    func drawLayer(in ctx: CGContext, scale: CGFloat, assets: Assets?) {
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        Renderer.drawNode(node, in: ctx, options: options(scale: scale, assets: assets))
        ctx.restoreGState()
    }
}

/// One file an export writes: what goes in it, as what, how big, and what it is called.
nonisolated struct ExportFile: Sendable {
    /// What it shows: one item, or for a PDF, a page each.
    let items: [ExportItem]
    let format: ExportFormat
    let size: ExportSize
    /// Its name without the extension. A "/" in it puts it in a folder of the name before.
    let name: String

    /// The pixels to a point it is drawn at, for a first item `drawn` big at 1×: the size's own,
    /// or what makes it as wide or as tall as asked.
    func scale(drawn: @autoclosure () -> CGSize) -> CGFloat {
        if let s = size.plainScale { return CGFloat(s) }
        return size.scale(for: drawn())
    }
}

nonisolated enum Exporter {
    /// How much of a JPEG, WebP or AVIF picture is kept when nothing else is asked, 0…1.
    static let defaultQuality = 0.9

    /// What exporting items in one format makes: a picture or an SVG each, or one PDF with a page
    /// each, named after the design unless it shows only one thing.
    static func files(_ items: [ExportItem], format: ExportFormat, scale: CGFloat, name: String) -> [ExportFile] {
        guard !items.isEmpty else { return [] }
        switch format {
        case .pdf:
            // Named after what it is when there is one of it, such as a carousel, a page a slide.
            let one = Set(items.map(\.node.id)).count == 1
            return [ExportFile(items: items, format: .pdf, size: .scale(1), name: one ? items[0].node.name : name)]
        case .svg:
            return items.map { ExportFile(items: [$0], format: .svg, size: .scale(1), name: $0.name) }
        case .png, .jpeg, .webp, .avif:
            let size = ExportSize.scale(Double(scale))
            return items.map { ExportFile(items: [$0], format: format, size: size, name: $0.name + size.suffix) }
        }
    }

    /// What exporting items as they are marked makes: a file for each preset of each, a PDF of
    /// one page among them.
    static func files(presetsOf items: [ExportItem]) -> [ExportFile] {
        items.flatMap { item in
            (item.node.exports ?? []).map { preset in
                ExportFile(items: [item], format: preset.format, size: preset.size, name: item.name + preset.nameSuffix)
            }
        }
    }

    /// Where a file goes by its name: in the folders its name asks for. Nothing in a name reaches
    /// outside the folder chosen.
    static func place(of file: ExportFile, in folder: URL) -> URL {
        let parts = file.name.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "-") }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        var place = folder
        for part in parts.dropLast() { place.appendPathComponent(part, isDirectory: true) }
        return place.appendingPathComponent(parts.last ?? "Export").appendingPathExtension(file.format.fileExtension)
    }

    /// The files already in `folder` that writing these would replace, each once.
    static func clashes(_ files: [ExportFile], in folder: URL) -> [URL] {
        var seen = Set<String>()
        return files.map { place(of: $0, in: folder) }.filter { seen.insert($0.path).inserted && FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Where each file goes, its folders made: under its own name, replacing what is there when
    /// `replacing`, otherwise numbered past it. Two files of one export never go to one place.
    static func destinations(of files: [ExportFile], in folder: URL, replacing: Bool) -> [URL?] {
        var taken = Set<String>()
        return files.map { file in
            let url = place(of: file, in: folder)
            let inside = url.deletingLastPathComponent()
            if inside.standardizedFileURL != folder.standardizedFileURL {
                guard (try? FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)) != nil else { return nil }
            }
            let chosen = free(url, replacing: replacing, taken: taken)
            taken.insert(chosen.path)
            return chosen
        }
    }

    /// The name itself, or with a number after it, "Card 2", when it is taken: by a file there,
    /// unless that is to be replaced, or by another file of the same export.
    fileprivate static func free(_ url: URL, replacing: Bool, taken: Set<String>) -> URL {
        var candidate = url
        var i = 2
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        func used(_ u: URL) -> Bool { taken.contains(u.path) || !replacing && FileManager.default.fileExists(atPath: u.path) }
        while used(candidate) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(i)").appendingPathExtension(ext)
            i += 1
        }
        return candidate
    }
}

// MARK: - What the Export sheet offers

/// What can be exported from where the design stands, as the Export sheet offers it: the layers
/// picked, each on its own and only as big as it is; the post of a deck in front; the artboards
/// they lie on; everything marked for export; or all the artboards. And how each is said.
struct ExportChoices {
    enum Scope: Hashable { case layers, post, artboards, marked, all }

    let doc: BezzleDocument
    /// The design as it is seen, a deck by the post in front (the Mac's `seenDoc`).
    let seen: BezzleDocument
    let selection: [UUID]
    /// The post of a deck in front.
    let front: (Node) -> Int?
    /// The design's name, for a PDF of several things.
    let name: String

    /// The picked layers that are not artboards, each to be exported on its own.
    var layers: [ExportItem] { selection.compactMap { ExportItem(layer: $0, in: doc) } }

    /// The artboards the picked layers lie on, or that are picked themselves.
    var pickedBoards: [Node] {
        let ids = Set(selection.map { doc.artboard(of: $0)?.id ?? $0 })
        return doc.artboards.filter { ids.contains($0.id) }
    }

    /// The deck picked, alone, whose post in front can go out by itself.
    var pickedDeck: Node? {
        let boards = pickedBoards
        return boards.count == 1 && boards[0].isDeck && boards[0].posts.count > 1 ? boards[0] : nil
    }

    /// Everything marked for export, as it is seen.
    var marked: [ExportItem] { ExportItem.marked(in: doc, seen: seen) }

    /// Whether there is anything at all to export.
    var isEmpty: Bool { doc.artboards.isEmpty && layers.isEmpty && marked.isEmpty }

    /// What can be chosen, the most particular first, which is what is chosen to begin with.
    var scopes: [Scope] {
        var out: [Scope] = []
        if !layers.isEmpty { out.append(.layers) }
        if pickedDeck != nil { out.append(.post) }
        let boards = pickedBoards.count
        if boards > 0 && (boards < doc.artboards.count || !layers.isEmpty) { out.append(.artboards) }
        if !marked.isEmpty { out.append(.marked) }
        // All of them, unless that is what the artboards picked already are.
        if boards < doc.artboards.count || out.isEmpty { out.append(.all) }
        return out
    }

    /// The scope wanted, when it is offered; else the first offered.
    func chosen(_ wanted: Scope?) -> Scope { wanted.flatMap { scopes.contains($0) ? $0 : nil } ?? scopes[0] }

    func items(_ scope: Scope) -> [ExportItem] {
        switch scope {
        case .layers: layers
        case .post: pickedDeck.map { ExportItem.items(for: $0, post: front($0)) } ?? []
        case .artboards: pickedBoards.flatMap(ExportItem.items(for:))
        case .marked: marked
        case .all: doc.artboards.flatMap(ExportItem.items(for:))
        }
    }

    /// What the export will write.
    func files(_ scope: Scope, format: ExportFormat, scale: CGFloat) -> [ExportFile] {
        scope == .marked ? Exporter.files(presetsOf: items(scope)) : Exporter.files(items(scope), format: format, scale: scale, name: name)
    }

    /// Whether all that goes out is slides of carousels, which keep a scale of their own.
    func onlySlides(_ scope: Scope) -> Bool {
        let items = items(scope)
        return !items.isEmpty && items.allSatisfy { $0.slide != nil }
    }

    /// Whether how much of the picture is kept matters to what goes out.
    func lossy(_ scope: Scope, format: ExportFormat) -> Bool {
        scope == .marked ? files(scope, format: format, scale: 1).contains { $0.format.isLossy } : format.isLossy
    }

    func title(_ scope: Scope) -> LocalizedStringResource {
        switch scope {
        case .layers:
            let picked = layers
            if picked.count > 1 { return "\(picked.count) layers" }
            return picked.first?.node.isGroup == true ? "This group" : "This layer"
        case .post: return "This post"
        case .artboards:
            if let deck = pickedDeck {
                // A narrow choice beside the others, so it may say less than the deck's own offer does.
                return LocalizedStringResource("export.all-posts", defaultValue: "All \(deck.posts.count) posts", comment: "Export choice: every post of the deck.")
            }
            return pickedBoards.count == 1 ? "Its artboard" : "\(pickedBoards.count) artboards"
        case .marked:
            return LocalizedStringResource("export.marked", defaultValue: "\(Set(marked.map(\.node.id)).count) marked",
                                           comment: "Export choice: every layer and artboard marked for export, each as its Export card says.")
        case .all: return "All \(doc.artboards.count)"
        }
    }

    /// What goes out, in words: a carousel by its slides, a deck by its posts.
    func names(_ items: [ExportItem], _ scope: Scope) -> String {
        guard let first = items.first else { return "" }
        if scope == .layers { return items.count == 1 ? first.name : String(localized: "\(items.count) layers") }
        if scope == .post { return items.count == 1 ? first.name : String(localized: "The \(items.count) slides of \(first.name)") }
        let boards = Set(items.map(\.node.id)).count
        let carousels = Set(items.filter { $0.slide != nil }.map(\.node.id)).count
        let decks = Set(items.filter { $0.post != nil }.map(\.node.id)).count
        let name = first.node.name
        if boards == 1, decks == 1, let posts = first.post?.count {
            return switch (posts == 1, carousels == 1) {
            case (true, false): String(localized: "The one post of \(name)")
            case (true, true): String(localized: "The one post of \(name), a slide each")
            case (false, false): String(localized: "The \(posts) posts of \(name)")
            case (false, true): String(localized: "The \(posts) posts of \(name), a slide each")
            }
        }
        if boards == 1 {
            guard carousels == 1 else { return first.name }
            return items.count == 1 ? String(localized: "The one slide of \(name)") : String(localized: "The \(items.count) slides of \(name)")
        }
        var parts = [String(localized: "\(boards) artboards")]
        if decks > 0 { parts.append(decks == 1 ? String(localized: "the deck a post each") : String(localized: "the decks a post each")) }
        if carousels > 0 { parts.append(carousels == 1 ? String(localized: "the carousel a slide each") : String(localized: "the carousels a slide each")) }
        return parts.joined(separator: ", ")
    }

    /// What goes out, in a sentence; `size` measures an item as it would go out, at 1×.
    func summary(_ scope: Scope, format: ExportFormat, scale: Double, size: (ExportItem) -> CGSize) -> String {
        let items = items(scope)
        guard let first = items.first else { return "" }
        if scope == .marked { return Self.listing(files(scope, format: format, scale: CGFloat(scale))) }
        let one = items.count == 1
        let names = names(items, scope)
        // A layer goes out only as big as what it paints, shadow and all, on nothing.
        let alone = scope == .layers ? (format.keepsTransparency ? String(localized: "on a transparent background") : String(localized: "on white")) : nil
        // Each part of the sentence is whole in itself, so it reads in any language once joined.
        var parts: [String?]
        switch format {
        case .pdf:
            parts = [String(localized: "\(names) as one PDF"), one ? nil : String(localized: "a page each"),
                     String(localized: "with text and shapes kept sharp at any size"), alone]
        case .svg:
            let lead = one ? String(localized: "\(names) as SVG") : String(localized: "\(names) as SVG, a file each")
            parts = [String(localized: "\(lead): shapes, text and gradients stay editable; background blurs come as pictures"), alone]
        case .png, .jpeg, .webp, .avif:
            var lead = names
            // One picture, or slides all the same size.
            let sizes = one ? [size(first)] : scope == .layers ? [] : items.map(size)
            if let s = sizes.first, sizes.allSatisfy({ $0 == s }) {
                lead = String(localized: "\(names) at \(Int((s.width * scale).rounded())) × \(Int((s.height * scale).rounded())) pixels")
            }
            parts = [lead, one ? nil : String(localized: "a file each"), alone]
        }
        return parts.compactMap { $0 }.joined(separator: ", ") + "."
    }

    /// How much of a picture is kept, as offered: WebP's top is lossless, and with no format given,
    /// the top is each format's best.
    static func qualities(for format: ExportFormat?) -> [(Double, LocalizedStringResource)] {
        let top: LocalizedStringResource = format == .webp ? "Lossless" : format == nil ? "Best" : .verbatim("100%")
        return [(0.6, .verbatim("60%")), (0.8, .verbatim("80%")), (0.9, .verbatim("90%")), (1, top)]
    }

    /// The files that will be written, by name: the first few, and how many more; said to be as
    /// marked, in the Export sheet, where other choices lie beside it.
    static func listing(_ files: [ExportFile], marked: Bool = true) -> String {
        let names = files.map { "\($0.name).\($0.format.fileExtension)" }
        guard !names.isEmpty else { return "" }
        let few = names.count <= 4
        let list = few ? Self.and(names) : names.prefix(3).joined(separator: ", ")
        let more = names.count - 3
        return switch (marked, few) {
        case (true, true): String(localized: "As marked: \(list).")
        case (true, false): String(localized: "As marked: \(list) and \(more) more.")
        case (false, true): list
        case (false, false): String(localized: "\(list) and \(more) more")
        }
    }

    /// Names joined as a list is said, "a, b and c", in the language the app speaks.
    private static func and(_ names: [String]) -> String {
        #if os(macOS)
        names.formatted(.list(type: .and))
        #else
        names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
        #endif
    }
}

// MARK: - Marked for export

nonisolated extension ExportPreset {
    /// The presets in a few words: each format once, with its sizes, "PNG 1× 2× 3× · SVG".
    static func summary(of presets: [ExportPreset]) -> String {
        var formats: [ExportFormat] = []
        var sizes: [ExportFormat: [String]] = [:]
        for p in presets {
            if sizes[p.format] == nil {
                formats.append(p.format)
                sizes[p.format] = []
            }
            if p.format.isPicture { sizes[p.format, default: []].append(p.size.shown) }
        }
        return formats.map { ([$0.title] + (sizes[$0] ?? [])).joined(separator: " ") }.joined(separator: " · ")
    }
}
