import AppKit
import ImageIO

/// Repeat grids: making one of the selection, changing how many cells it has and how far apart
/// they are, and filling its cells with words and pictures of their own. See `RepeatGrid`.
extension DocumentStore {
    // MARK: Making and unmaking

    /// What would be repeated: the layers selected, if they lie together and none is an artboard,
    /// a grid or a grid's cell.
    private var repeatable: [UUID]? {
        let ids = selection.filter { doc.node($0)?.locked == false }
        guard !ids.isEmpty, ids.count == selection.count else { return nil }
        let parents = Set(ids.map { doc.parent(of: $0)?.id })
        guard parents.count == 1, let parent = parents.first else { return nil }
        if let parent, doc.node(parent)?.isRepeatGrid == true { return nil }
        guard ids.allSatisfy({ doc.node($0).map { !$0.isArtboard && !$0.isRepeatGrid } == true }) else { return nil }
        return ids
    }

    var canMakeRepeatGrid: Bool { repeatable != nil }

    /// Makes the selection a repeat grid of one cell, to be pulled out into rows and columns: one
    /// layer is the cell itself, several are grouped into one first.
    func makeRepeatGrid() {
        guard let ids = repeatable else { return }
        var made: UUID?
        edit("Make Repeat Grid") { doc in made = Self.makeRepeatGrid(of: ids, in: &doc) }
        if let made { selection = [made] }
    }

    /// Puts layers that lie together into a new repeat grid, where the topmost of them was, and
    /// returns its id.
    @discardableResult
    static func makeRepeatGrid(of ids: [UUID], in doc: inout BezzleDocument, columns: Int = 1, rows: Int = 1,
                               columnGap: CGFloat? = nil, rowGap: CGFloat? = nil, name: String? = nil) -> UUID? {
        guard let firstID = ids.first else { return nil }
        let parent = doc.parent(of: firstID)?.id
        let path = parent.flatMap { doc.path(of: $0) }
        var siblings = path.map { doc[$0].children } ?? doc.nodes
        let chosen = Set(ids)
        guard let top = siblings.lastIndex(where: { chosen.contains($0.id) }) else { return nil }
        let picked = siblings.filter { chosen.contains($0.id) }
        // In a group of their own, they keep where they are: it starts at its parent's top left
        // and is fitted round them.
        var cell = picked[0]
        if picked.count > 1 {
            cell = Node(kind: .group, name: doc.nextName(for: .group), frame: .zero)
            cell.children = picked
        }
        let size = RepeatGrid.box(of: cell).size
        let gap = RepeatGrid.gap(for: size)
        var grid = Node(kind: .group, name: name ?? Self.gridName(in: doc), frame: .zero)
        grid.grid = RepeatGrid(columns: RepeatGrid.clamped(columns), rows: RepeatGrid.clamped(rows),
                               columnGap: columnGap ?? gap, rowGap: rowGap ?? gap)
        grid.children = [cell]
        siblings.removeAll { chosen.contains($0.id) }
        siblings.insert(grid, at: top + 1 - picked.count)
        if let path {
            var holder = doc[path]
            holder.children = siblings
            doc[path] = holder
        } else {
            doc.nodes = siblings
        }
        return grid.id
    }

    private static func gridName(in doc: BezzleDocument) -> String {
        let taken = Set(doc.allNodes.map(\.name))
        var i = 1
        while taken.contains(String(localized: "Repeat Grid \(i)")) { i += 1 }
        return String(localized: "Repeat Grid \(i)")
    }

    /// The selected grid, or the grid the selected layer lies in.
    var selectedGrid: Node? {
        guard selection.count == 1 else { return nil }
        return grid(holding: selection[0])
    }

    /// The grid a layer is, or the nearest one it lies in.
    func grid(holding id: UUID) -> Node? {
        if let n = doc.node(id), n.isRepeatGrid { return n }
        return doc.ancestors(of: id).last { $0.isRepeatGrid }
    }

    /// Changes how many cells a grid has, or how far apart they are.
    func changeGrid(_ id: UUID, _ action: LocalizedStringResource, _ change: @escaping (inout RepeatGrid) -> Void) {
        update([id], action) { node in
            guard var spec = node.grid else { return }
            change(&spec)
            spec.columns = RepeatGrid.clamped(spec.columns)
            spec.rows = RepeatGrid.clamped(spec.rows)
            spec.columnGap = spec.columnGap.rounded()
            spec.rowGap = spec.rowGap.rounded()
            node.grid = spec
        }
    }

    /// Makes a grid a plain group of the cells it has, each a layer of its own from then on.
    func ungroupGrid(_ id: UUID) {
        update([id], "Ungroup Grid") { $0.grid = nil }
    }

    /// Shows `change` to particular layers on the canvas without making it, as `showPreview` does
    /// for the selection: a grid's size, or words in its cells, while a layer in a cell is selected.
    func showPreview(_ key: String, on ids: [UUID], _ change: @escaping (inout Node) -> Void) {
        preview = Preview(key: key, ids: ids, change: change)
    }

    // MARK: What the cells hold

    /// What a grid's cells each hold of their own: its first cell's text layers and the shapes
    /// that can hold a picture, as they are read, top to bottom and left to right.
    func slots(of grid: Node) -> [Node] {
        guard let layout = RepeatGrid.layout(of: grid) else { return [] }
        let first = grid.children[layout.first]
        let cell = RepeatGrid.box(of: first).size
        var found: [(Node, CGPoint)] = []
        func visit(_ n: Node, at origin: CGPoint) {
            let here = CGPoint(x: origin.x + n.frame.minX, y: origin.y + n.frame.minY)
            // A shape as big as the cell is what the cell is drawn on, not a place for a picture,
            // unless one is there already.
            let backing = n.frame.width * n.frame.height >= cell.width * cell.height * 0.85 && n.id != first.id
            if n.kind == .text || ([.rectangle, .ellipse, .path].contains(n.kind) && (!backing || n.fill.image != nil)) { found.append((n, here)) }
            if n.isGroup { for c in n.children { visit(c, at: here) } }
        }
        visit(first, at: .zero)
        return found.sorted { a, b in abs(a.1.y - b.1.y) > 2 ? a.1.y < b.1.y : a.1.x < b.1.x }.map(\.0)
    }

    /// The same layer in each of a grid's cells, as they are read: the first cell's layer is `slot`.
    func copies(of slot: UUID, in grid: Node) -> [UUID] {
        (grid.grid?.cells ?? []).map { slot.mixed(RepeatGrid.key($0)) }.filter { doc.node($0) != nil }
    }

    /// A layer of some cell, as it is in the first.
    func slot(of id: UUID) -> UUID? {
        guard let grid = grid(holding: id), grid.id != id, let found = RepeatGrid.cell(of: id, in: grid, doc: doc) else { return nil }
        return id.mixed(RepeatGrid.key(found.cell))
    }

    /// Gives each cell's copy of a text layer the next of `values`, from the first cell on, and
    /// round again when there are fewer of them than cells.
    func fill(_ slot: UUID, in gridID: UUID, with values: [String], action: LocalizedStringResource = "Fill Cells") {
        guard let grid = doc.node(gridID), !values.isEmpty else { return }
        let ids = copies(of: slot, in: grid)
        edit(action) { doc in
            for (i, id) in ids.enumerated() {
                doc.update(id) { n in
                    guard n.kind == .text else { return }
                    n.text = values[i % values.count]
                    n.refit()
                }
            }
        }
    }

    /// Gives each cell's copy of a shape the next of these pictures, and round again.
    func fill(_ slot: UUID, in gridID: UUID, withPictures pictures: [ImageFill], action: LocalizedStringResource = "Fill Cells with Pictures") {
        guard let grid = doc.node(gridID), !pictures.isEmpty else { return }
        let ids = copies(of: slot, in: grid)
        edit(action) { doc in
            for (i, id) in ids.enumerated() {
                doc.update(id) { n in
                    guard [.rectangle, .ellipse, .path].contains(n.kind) else { return }
                    n.fill.on = true
                    n.fill.image = pictures[i % pictures.count]
                }
            }
        }
    }

    /// What each cell holds in a slot: its words, or its picture.
    private func contents(of slot: UUID, in grid: Node) -> [(text: String?, image: ImageFill?)] {
        copies(of: slot, in: grid).compactMap { doc.node($0) }.map { ($0.kind == .text ? $0.text : nil, $0.fill.image) }
    }

    /// Mixes up which cell holds which of the words or pictures in a slot.
    func shuffle(_ slot: UUID, in gridID: UUID) {
        guard let grid = doc.node(gridID) else { return }
        var held = contents(of: slot, in: grid)
        guard held.count > 1 else { return }
        let was = held
        // Never the order it was in.
        for _ in 0..<8 where held.map(\.text) == was.map(\.text) && held.map(\.image) == was.map(\.image) { held.shuffle() }
        let ids = copies(of: slot, in: grid)
        edit("Shuffle Cells") { doc in
            for (id, h) in zip(ids, held) {
                doc.update(id) { n in
                    if n.kind == .text, let text = h.text {
                        n.text = text
                        n.refit()
                    } else if n.kind != .text {
                        n.fill.image = h.image
                    }
                }
            }
        }
    }

    /// Gives every cell what one cell holds in a slot.
    func sameInEveryCell(_ id: UUID) {
        guard let grid = grid(holding: id), let slot = slot(of: id), let source = doc.node(id) else { return }
        if source.kind == .text {
            fill(slot, in: grid.id, with: [source.text ?? ""], action: "Same in Every Cell")
        } else if let image = source.fill.image {
            fill(slot, in: grid.id, withPictures: [image], action: "Same in Every Cell")
        } else {
            let ids = copies(of: slot, in: grid)
            edit("Same in Every Cell") { doc in for id in ids { doc.update(id) { $0.fill.image = nil } } }
        }
    }

    /// Which of a grid's text layers words from text go to, and what each gets: a line each, or,
    /// for a table with a heading row such as a CSV file, a column each, to the text layer named as
    /// the column is, and the rest in order.
    func assignments(from text: String, in grid: Node, startingWith preferred: UUID? = nil) -> [(slot: UUID, values: [String])] {
        let texts = slots(of: grid).filter { $0.kind == .text }
        guard !texts.isEmpty else { return [] }
        if let table = DataTable(text), table.columns.count > 1 {
            var filled: [(slot: UUID, values: [String])] = []
            var left = texts
            var columns = table.columns
            for (i, column) in columns.enumerated().reversed() {
                if let at = left.firstIndex(where: { $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(column.title) == .orderedSame }) {
                    filled.append((left[at].id, column.values))
                    left.remove(at: at)
                    columns.remove(at: i)
                }
            }
            for (slot, column) in zip(left, columns) { filled.append((slot.id, column.values)) }
            return filled.filter { !$0.values.isEmpty }
        }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }
        return [(preferred.flatMap { p in texts.contains { $0.id == p } ? p : nil } ?? texts[0].id, lines)]
    }

    /// Fills a grid's text layers from text (see `assignments`). Returns how many were filled.
    @discardableResult
    func fill(_ gridID: UUID, from text: String, startingWith preferred: UUID? = nil) -> Int {
        guard let grid = doc.node(gridID) else { return 0 }
        let filled = assignments(from: text, in: grid, startingWith: preferred)
        let each = filled.map { (copies(of: $0.slot, in: grid), $0.values) }
        guard !each.isEmpty else { return 0 }
        edit("Fill Cells") { doc in
            for (ids, values) in each {
                for (i, id) in ids.enumerated() {
                    doc.update(id) { n in
                        guard n.kind == .text else { return }
                        n.text = values[i % values.count]
                        n.refit()
                    }
                }
            }
        }
        return filled.count
    }

    // MARK: Pictures

    /// Copies a picture into the design's own images, so it goes wherever the design does, and
    /// returns it as a fill. A design kept as a single file becomes a package first.
    func importPicture(_ file: URL) -> ImageFill? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var w = info[kCGImagePropertyPixelWidth] as? Int, var h = info[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0
        else { return nil }
        // Turned on its side by its orientation, it is as wide as it is tall.
        if let orientation = info[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) { swap(&w, &h) }
        if !DesignFile.isPackage(url) {
            save()
            Self.finishSaving()
            do {
                try DesignFile.makePackage(url)
                becamePackage()
            } catch {
                NSLog("Bezzle could not make %@ a package: %@", url.path, error.localizedDescription)
                return nil
            }
        }
        let images = url.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
        let ext = file.pathExtension.isEmpty ? "png" : file.pathExtension.lowercased()
        let asset = "\(UUID().uuidString).\(ext)"
        do {
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: images.appendingPathComponent(asset))
        } catch {
            NSLog("Bezzle could not copy %@ into the design: %@", file.path, error.localizedDescription)
            return nil
        }
        return ImageFill(asset: asset, mode: .cover, size: CGSize(width: w, height: h))
    }

    /// The pictures among some files, and those in any folders among them, in the Finder's order by name.
    static func pictureFiles(in urls: [URL]) -> [URL] {
        let types = Set(["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "webp", "bmp"])
        var found: [URL] = []
        for url in urls {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            if isFolder.boolValue {
                let inside = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                found += inside.filter { types.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else if types.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        return found
    }

    /// Asks for pictures, or a folder of them, and fills each cell's copy of a shape with the next.
    func choosePictures(for slot: UUID, in gridID: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = String(localized: "Choose pictures, or a folder of them. Each cell gets the next one.")
        guard panel.runModal() == .OK else { return }
        let pictures = Self.pictureFiles(in: panel.urls).compactMap(importPicture)
        fill(slot, in: gridID, withPictures: pictures)
    }

    /// Asks for a text or CSV file and fills the grid's text layers from it.
    func chooseData(for gridID: UUID, startingWith slot: UUID? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .commaSeparatedText, .tabSeparatedText, .text]
        panel.message = String(localized: "Choose a text file of one line per cell, or a CSV file whose column names are the names of text layers in the grid.")
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        fill(gridID, from: text, startingWith: slot)
    }
}

/// A table read from CSV or tab-separated text: its first row names its columns.
nonisolated struct DataTable {
    struct Column {
        var title: String
        var values: [String]
    }

    var columns: [Column]

    /// Nil for text that is no table: lines without a comma, semicolon or tab between columns.
    init?(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return nil }
        let head = lines[0]
        let separator: Character? = ["\t", ";", ","].first { c in head.contains(c) && lines.dropFirst().allSatisfy { $0.contains(c) } }
        guard let separator else { return nil }
        let rows = lines.map { Self.fields(of: $0, separator: separator) }
        columns = rows[0].enumerated().map { i, title in
            Column(title: title.trimmingCharacters(in: .whitespaces), values: rows.dropFirst().map { i < $0.count ? $0[i].trimmingCharacters(in: .whitespaces) : "" })
        }
    }

    /// The fields of one line, with quoted fields that hold the separator or doubled quotes.
    static func fields(of line: String, separator: Character) -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(line)[...]
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" {
                    if chars.first == "\"" { field.append("\""); chars.removeFirst() } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == separator {
                fields.append(field)
                field = ""
            } else {
                field.append(c)
            }
        }
        fields.append(field)
        return fields
    }
}
