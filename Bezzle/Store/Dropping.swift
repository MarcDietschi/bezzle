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

extension DocumentStore {
    /// What dropping something at a canvas point, on a layer (or on nothing), would do (the
    /// shared `BezzleDocument.dropPlan`). Nil where it can go nowhere.
    func plan(for dropped: Dropped, at p: CGPoint, on target: UUID?) -> DropPlan? {
        guard !isReadOnly else { return nil }
        return doc.dropPlan(pictures: dropped.sizes, text: dropped.text, at: p, on: target)
    }

    /// The topmost mockup screen under a canvas point (the shared `BezzleDocument.screen(at:)`).
    func screen(at p: CGPoint) -> UUID? { doc.screen(at: p) }

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
            edit(fills.count == 1 && shapes.count == 1 ? "Add Picture" : "Add Pictures") { doc in doc.fill(shapes, withPictures: fills) }
            if let target { selection = [target] }
            return true
        case .place(let frames, let board):
            let fills = zip(dropped.pictures, frames).compactMap { file, frame in importPicture(file).map { (file, frame, $0) } }
            guard !fills.isEmpty else { return false }
            var made: [UUID] = []
            edit(fills.count == 1 ? "Add Picture" : "Add Pictures") { doc in
                made = doc.place(pictures: fills.map { ($0.0.deletingPathExtension().lastPathComponent, $0.1, $0.2) }, onto: board)
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
