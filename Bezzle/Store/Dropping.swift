import AppKit
import ImageIO

/// Files and words dragged onto the canvas from elsewhere: pictures, and the lines of a text or
/// CSV file, or of words dragged from another app.
struct Dropped {
    var pictures: [URL] = []
    /// Each picture's own size in pixels, upright, read from its file without opening it.
    var sizes: [CGSize] = []
    var text: String?

    init(_ pasteboard: NSPasteboard) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let lists = urls.filter { ["txt", "text", "csv", "tsv"].contains($0.pathExtension.lowercased()) }
        let text = lists.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? (urls.isEmpty ? pasteboard.string(forType: .string) : nil)
        self.init(pictures: DocumentStore.pictureFiles(in: urls), text: text)
    }

    init(pictures: [URL] = [], text: String? = nil) {
        var kept: [URL] = [], sizes: [CGSize] = []
        for url in pictures {
            guard let size = Self.size(of: url) else { continue }
            kept.append(url)
            sizes.append(size)
        }
        self.pictures = kept
        self.sizes = sizes
        self.text = text
    }

    static func size(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = info[kCGImagePropertyPixelWidth] as? Int, let h = info[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0
        else { return nil }
        // Turned on its side by its orientation, it is as wide as it is tall.
        let turned = (info[kCGImagePropertyOrientation] as? Int).map { (5...8).contains($0) } ?? false
        return turned ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }
}

/// What letting go of something dragged in would do, worked out once, so that what the canvas
/// shows while it is held over a place is what happens when it is let go there.
enum DropPlan {
    /// The pictures fill these shapes, the first picture the first shape and round again: one
    /// shape, or the same shape in every cell of a repeat grid.
    case fill([UUID])
    /// Each picture is a layer of its own, at these frames on the canvas, on an artboard or on
    /// the canvas itself.
    case place([CGRect], onto: UUID?)
    /// The words go into these text layers of a grid's cells, a line or a column each.
    case words(grid: UUID, layers: [UUID], columns: Int, lines: Int)
    /// Several pictures, each into this shape in a post of its own, from the post it is in on:
    /// the artboard becomes a deck if it is not one, and gains posts as it needs. See `Deck`.
    case posts(shape: UUID, count: Int)
    /// Lines, or the rows of a table, each into this text in a post of its own, the same way.
    case postWords(text: UUID, count: Int)
}

extension DocumentStore {
    /// What dropping something at a canvas point, on a layer (or on nothing), would do: pictures
    /// fill the shape or the letters of the text they are dropped on, one each for one repeated in
    /// a grid, and anywhere else are each a layer of their own; words fill a grid's text layers.
    /// Nil where it can go nowhere.
    func plan(for dropped: Dropped, at p: CGPoint, on target: UUID?) -> DropPlan? {
        guard !isReadOnly else { return nil }
        if !dropped.pictures.isEmpty {
            if let target, let node = doc.node(target), [.rectangle, .ellipse, .path, .text].contains(node.kind), !node.locked {
                if dropped.pictures.count > 1, let grid = grid(holding: target), let slot = slot(of: target) {
                    return .fill(copies(of: slot, in: grid))
                }
                // Several onto a shape on an artboard: a post each.
                if dropped.pictures.count > 1, doc.artboard(of: target).map({ !$0.locked }) == true {
                    return .posts(shape: target, count: dropped.pictures.count)
                }
                return .fill([target])
            }
            // As big as each is, a point a pixel, but no more than about half the artboard either
            // way, so a photo comes in beside what is there rather than over all of it; fanned out a little.
            let board = doc.artboard(at: p)
            let room = board.map { CGSize(width: $0.frame.width * 0.6, height: $0.frame.height * 0.6) } ?? CGSize(width: 480, height: 480)
            let frames = dropped.sizes.enumerated().map { i, own -> CGRect in
                let k = min(1, room.width / max(own.width, 1), room.height / max(own.height, 1))
                let size = CGSize(width: max(1, (own.width * k).rounded()), height: max(1, (own.height * k).rounded()))
                return CGRect(origin: CGPoint(x: (p.x - size.width / 2).rounded() + CGFloat(i * 24), y: (p.y - size.height / 2).rounded() + CGFloat(i * 24)),
                              size: size)
            }
            return .place(frames, onto: board?.id)
        }
        guard let text = dropped.text, let target else { return nil }
        guard let grid = grid(holding: target) else {
            // Onto a text on an artboard: a line, or a table's row, a post.
            guard doc.node(target)?.kind == .text, doc.artboard(of: target).map({ !$0.locked }) == true else { return nil }
            let rows = DataTable(text).flatMap { $0.columns.count > 1 ? $0.columns.map(\.values.count).max() : nil }
                ?? text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            return rows > 1 ? .postWords(text: target, count: rows) : nil
        }
        let slot = slot(of: target).flatMap { doc.node($0)?.kind == .text ? $0 : nil }
        let filled = assignments(from: text, in: grid, startingWith: slot)
        guard !filled.isEmpty else { return nil }
        return .words(grid: grid.id, layers: filled.flatMap { copies(of: $0.slot, in: grid) },
                      columns: filled.count, lines: filled.map(\.values.count).max() ?? 0)
    }

    func canDrop(_ dropped: Dropped, on target: UUID?, at p: CGPoint = .zero) -> Bool {
        plan(for: dropped, at: p, on: target) != nil
    }

    /// Does what `plan` says dropping there would do.
    @discardableResult
    func drop(_ dropped: Dropped, at p: CGPoint, on target: UUID?) -> Bool {
        switch plan(for: dropped, at: p, on: target) {
        case .fill(let shapes):
            let fills = dropped.pictures.compactMap(importPicture)
            guard !fills.isEmpty else { return false }
            edit(fills.count == 1 && shapes.count == 1 ? "Add Picture" : "Add Pictures") { doc in
                for (i, id) in shapes.enumerated() {
                    doc.update(id) { n in
                        n.fill.on = true
                        n.fill.image = fills[i % fills.count]
                        // All of a text's letters show it.
                        n.clearLetterColors()
                    }
                }
            }
            if let target { selection = [target] }
            return true
        case .place(let frames, let board):
            let fills = zip(dropped.pictures, frames).compactMap { file, frame in importPicture(file).map { (file, frame, $0) } }
            guard !fills.isEmpty else { return false }
            var made: [UUID] = []
            edit(fills.count == 1 ? "Add Picture" : "Add Pictures") { doc in
                for (file, frame, image) in fills {
                    var node = Node(kind: .rectangle, name: file.deletingPathExtension().lastPathComponent, frame: frame)
                    node.fill = Fill(color: .shape, image: image)
                    doc.attach(node, to: board)
                    made.append(node.id)
                }
            }
            selection = made
            return true
        case .posts(let shape, _):
            let fills = dropped.pictures.compactMap(importPicture)
            guard !fills.isEmpty else { return false }
            spread(fills, from: shape, action: "Add Pictures")
            selection = [shape]
            return true
        case .postWords(let text, _):
            guard let words = dropped.text else { return false }
            if let table = DataTable(words), table.columns.count > 1 {
                spread(table: table, from: text)
            } else {
                spread(words.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, from: text)
            }
            selection = [text]
            return true
        case .words(let grid, _, _, _):
            guard let text = dropped.text, let target else { return false }
            let slot = slot(of: target).flatMap { doc.node($0)?.kind == .text ? $0 : nil }
            let filled = fill(grid, from: text, startingWith: slot)
            if filled > 0 { selection = [grid] }
            return filled > 0
        case nil:
            return false
        }
    }
}
