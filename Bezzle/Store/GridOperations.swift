import AppKit
import ImageIO

/// Repeat grids: making one of the selection, changing how many cells it has and how far apart
/// they are, and filling its cells with words and pictures of their own. See `RepeatGrid`.
extension DocumentStore {
    // MARK: Making and unmaking

    /// What would be repeated (shared: `BezzleDocument.repeatable`).
    private var repeatable: [UUID]? { doc.repeatable(selection) }

    var canMakeRepeatGrid: Bool { repeatable != nil }

    /// Makes the selection a repeat grid of one cell, to be pulled out into rows and columns: one
    /// layer is the cell itself, several are grouped into one first.
    func makeRepeatGrid() {
        guard let ids = repeatable else { return }
        var made: UUID?
        edit("Make Repeat Grid") { doc in made = Self.makeRepeatGrid(of: ids, in: &doc) }
        if let made { selection = [made] }
    }

    /// Puts layers that lie together into a new repeat grid (shared: `BezzleDocument.makeRepeatGrid`).
    @discardableResult
    static func makeRepeatGrid(of ids: [UUID], in doc: inout BezzleDocument, columns: Int = 1, rows: Int = 1,
                               columnGap: CGFloat? = nil, rowGap: CGFloat? = nil, name: String? = nil) -> UUID? {
        doc.makeRepeatGrid(of: ids, columns: columns, rows: rows, columnGap: columnGap, rowGap: rowGap, name: name)
    }

    /// The selected grid, or the grid the selected layer lies in.
    var selectedGrid: Node? {
        guard selection.count == 1 else { return nil }
        return grid(holding: selection[0])
    }

    /// The grid a layer is, or the nearest one it lies in.
    func grid(holding id: UUID) -> Node? { doc.grid(holding: id) }

    /// Changes how many cells a grid has, or how far apart they are.
    func changeGrid(_ id: UUID, _ action: LocalizedStringResource, _ change: @escaping (inout RepeatGrid) -> Void) {
        edit(action) { $0.changeGrid(id, change) }
    }

    /// Makes a grid a plain group of the cells it has, each a layer of its own from then on.
    func ungroupGrid(_ id: UUID) {
        edit("Ungroup Grid") { $0.ungroupGrid(id) }
    }

    /// Shows `change` to particular layers on the canvas without making it, as `showPreview` does
    /// for the selection: a grid's size, or words in its cells, while a layer in a cell is selected.
    func showPreview(_ key: String, on ids: [UUID], _ change: @escaping (inout Node) -> Void) {
        preview = Preview(key: key, ids: ids, change: change)
    }

    // MARK: What the cells hold

    /// What a grid's cells each hold of their own (the shared `BezzleDocument.slots(of:)`).
    func slots(of grid: Node) -> [Node] { doc.slots(of: grid) }

    /// The same layer in each of a grid's cells, as they are read.
    func copies(of slot: UUID, in grid: Node) -> [UUID] { doc.copies(of: slot, in: grid) }

    /// A layer of some cell, as it is in the first.
    func slot(of id: UUID) -> UUID? { doc.slot(of: id) }

    /// Gives each cell's copy of a text layer the next of `values`, from the first cell on, and
    /// round again when there are fewer of them than cells.
    func fill(_ slot: UUID, in gridID: UUID, with values: [String], action: LocalizedStringResource = "Fill Cells") {
        guard doc.node(gridID) != nil, !values.isEmpty else { return }
        edit(action) { $0.fillCells(slot, in: gridID, with: values) }
    }

    /// Gives each cell's copy of a shape the next of these pictures, and round again.
    func fill(_ slot: UUID, in gridID: UUID, withPictures pictures: [ImageFill], action: LocalizedStringResource = "Fill Cells with Pictures") {
        guard doc.node(gridID) != nil, !pictures.isEmpty else { return }
        edit(action) { $0.fillCells(slot, in: gridID, withPictures: pictures) }
    }

    /// Mixes up which cell holds which of the words or pictures in a slot.
    func shuffle(_ slot: UUID, in gridID: UUID) {
        guard let grid = doc.node(gridID), doc.cellContents(slot, in: grid).count > 1 else { return }
        edit("Shuffle Cells") { $0.shuffleCells(slot, in: gridID) }
    }

    /// Gives every cell what one cell holds in a slot.
    func sameInEveryCell(_ id: UUID) {
        guard grid(holding: id) != nil, slot(of: id) != nil, doc.node(id) != nil else { return }
        edit("Same in Every Cell") { $0.sameInEveryCell(id) }
    }

    /// Which of a grid's text layers words from text go to (the shared `assignments`).
    func assignments(from text: String, in grid: Node, startingWith preferred: UUID? = nil) -> [(slot: UUID, values: [String])] {
        doc.assignments(from: text, in: grid, startingWith: preferred)
    }

    /// Fills a grid's text layers from text (see `assignments`). Returns how many were filled.
    @discardableResult
    func fill(_ gridID: UUID, from text: String, startingWith preferred: UUID? = nil) -> Int {
        guard let grid = doc.node(gridID), !assignments(from: text, in: grid, startingWith: preferred).isEmpty else { return 0 }
        var filled = 0
        edit("Fill Cells") { filled = $0.fillCells(gridID, from: text, startingWith: preferred) }
        return filled
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
            // Inside the design only while it is there: never its package made anew (`DesignFile.makeFolder`).
            try DesignFile.makeFolder(images, in: url)
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
