import AppKit
import Observation

enum Tool: String, CaseIterable {
    case select, artboard, rectangle, ellipse, line, pen, text

    var title: String {
        switch self {
        case .select: "Select"
        case .artboard: "Artboard"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .pen: "Pen"
        case .text: "Text"
        }
    }

    var key: String {
        switch self {
        case .select: "V"
        case .artboard: "A"
        case .rectangle: "R"
        case .ellipse: "E"
        case .line: "L"
        case .pen: "P"
        case .text: "T"
        }
    }

    static func forKey(_ key: String) -> Tool? {
        allCases.first { $0.key.lowercased() == key.lowercased() }
    }
}

/// A line the canvas draws while something snaps to it, in canvas points.
struct Guide: Equatable {
    var from: CGPoint
    var to: CGPoint
}

/// One open design: the document itself, what is selected, how it is looked at, and the undo
/// history. Every change to the document goes through `edit`, which records it for Undo and
/// saves the file a moment later. There is no Save: a design is always on disk.
@Observable
final class DocumentStore {
    private(set) var doc: BezzleDocument {
        didSet {
            version += 1
            if !doc.hasSameLayers(as: oldValue) { layersVersion += 1 }
        }
    }
    /// Counts the changes that added, took away or moved layers among the others.
    @ObservationIgnored private var layersVersion = 0
    /// Counts the document's changes, so what is worked out from it is worked out once per change.
    private(set) var version = 0
    @ObservationIgnored private var colorsWorkedOut: (version: Int, colors: [RGBA])?
    /// Paths' points, read from their path data once per change: the canvas, the inspector and the
    /// pen all ask for those of the path being edited many times a frame.
    @ObservationIgnored var pointsWorkedOut: (version: Int, points: [UUID: BezierPath]) = (-1, [:])
    @ObservationIgnored private var countWorkedOut: (version: Int, count: Int)?
    var selection: [UUID] = [] {
        didSet { if selection != oldValue { selectionChanged() } }
    }
    var tool: Tool = .select {
        didSet {
            guard tool != oldValue else { return }
            // The pen works on the points being edited; any other drawing tool leaves them.
            if tool != .select && tool != .pen { editingPath = nil }
            guides = []
        }
    }
    var viewport = Viewport() {
        // Where the design was looked at is kept too, but there is no hurry about it.
        didSet { if viewport != oldValue { scheduleSave(after: 2000) } }
    }
    /// The layer under the pointer, outlined on the canvas.
    var hovered: UUID?
    /// Smart guides showing while something snaps.
    var guides: [Guide] = []
    /// The size shown in a pill under a layer being drawn or resized, and where (canvas points).
    var measurement: (text: String, rect: CGRect)?
    /// The text layer being typed into.
    var editingText: UUID?
    /// The path whose points are being edited, shown on the canvas in place of its frame.
    var editingPath: UUID? {
        didSet { if editingPath != oldValue { selectedPoints = [] } }
    }
    /// The points picked out on it.
    var selectedPoints: Set<PathPoint> = []
    /// Whether the layers list is out.
    var showsLayers = true
    /// The size of the canvas on screen, for zooming from the menus.
    var canvasSize: CGSize = .zero
    /// The last artboard size added from the presets, so a new artboard matches the others.
    var lastPreset: CGSize?
    /// A change shown on the canvas but not made: what a preset under the pointer would do.
    var preview: Preview?

    struct Preview {
        /// Which control shows it, so only that control takes it away again.
        let key: String
        let ids: [UUID]
        let change: (inout Node) -> Void
        /// Each one shown is a new one, even from the same control, such as the next colour
        /// along, so the canvas can ease from one to the next.
        let token = UUID()
    }

    private(set) var url: URL
    /// Set by the window; Undo and Redo in the Edit menu use it.
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var gestureStart: Snapshot?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The canvas on screen, for starting to type into a text layer from elsewhere.
    @ObservationIgnored weak var canvas: CanvasView?
    /// Whether the export panel is showing.
    var exporting = false
    /// What bringing the design in from Adobe XD could only approximate, shown until read.
    var importReport: XDReport?

    private struct Snapshot {
        var doc: BezzleDocument
        var selection: [UUID]
    }

    init(url: URL, document: BezzleDocument) {
        self.url = url
        self.doc = document
        assets = Assets(design: url)
        if let v = document.viewport { viewport = v }
    }

    convenience init(opening url: URL) throws {
        self.init(url: url, document: try DesignFile.read(url))
    }

    /// The design's pictures, read from its package as they are drawn.
    @ObservationIgnored private(set) var assets: Assets

    var name: String { url.deletingPathExtension().lastPathComponent }

    // MARK: Changing the document

    /// Changes the document as one step of the undo history, named for the Edit menu. Inside a
    /// gesture the change is folded into the gesture's one step.
    func edit(_ action: String, _ change: (inout BezzleDocument) -> Void) {
        let before = Snapshot(doc: doc, selection: selection)
        var next = doc
        change(&next)
        next.fitGroups(since: doc)
        guard next != doc else { return }
        doc = next
        if gestureStart == nil { record(before, action) }
        scheduleSave()
    }

    /// Starts a drag, a scrub or anything else made of many small changes that undo as one.
    func beginGesture() {
        if gestureStart == nil { gestureStart = Snapshot(doc: doc, selection: selection) }
    }

    func endGesture(_ action: String) {
        guard let start = gestureStart else { return }
        gestureStart = nil
        if start.doc != doc { record(start, action) }
        guides = []
        measurement = nil
    }

    /// Puts everything back as it was when the gesture started (Escape during a drag).
    func cancelGesture() {
        guard let start = gestureStart else { return }
        gestureStart = nil
        doc = start.doc
        selection = start.selection
        guides = []
        measurement = nil
    }

    var inGesture: Bool { gestureStart != nil }

    private func record(_ before: Snapshot, _ action: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { store in
            let now = Snapshot(doc: store.doc, selection: store.selection)
            store.doc = before.doc
            store.selection = before.selection.filter { store.doc.path(of: $0) != nil }
            store.editingText = nil
            store.record(now, action)
            store.scheduleSave()
        }
        undoManager.setActionName(action)
    }

    private func selectionChanged() {
        if let editing = editingText, !selection.contains(editing) { editingText = nil }
        if let editing = editingPath, selection != [editing] { editingPath = nil }
        preview = nil
    }

    /// Shows `change` to the selection on the canvas without making it, or with nil takes away
    /// the preview `key` showed.
    func showPreview(_ key: String, _ change: ((inout Node) -> Void)?) {
        if let change {
            preview = Preview(key: key, ids: selection, change: change)
        } else if preview?.key == key {
            preview = nil
        }
    }

    /// The document as the canvas shows it: with the preview, if there is one.
    var shownDoc: BezzleDocument {
        guard let preview else { return doc }
        var shown = doc
        for id in preview.ids {
            shown.update(id) { node in
                preview.change(&node)
                node.refit()
            }
        }
        return shown
    }

    /// The colours the design uses, the most used first, without their transparency.
    var designColors: [RGBA] {
        if let worked = colorsWorkedOut, worked.version == version { return worked.colors }
        let colors = countColors()
        colorsWorkedOut = (version, colors)
        return colors
    }

    /// How many layers there are.
    var layerCount: Int {
        if let worked = countWorkedOut, worked.version == layersVersion { return worked.count }
        let count = doc.layerCount
        countWorkedOut = (layersVersion, count)
        return count
    }

    /// The colours used on each artboard and loose layer, in the order met, with how often, so
    /// that after a change only what changed is counted again.
    private struct Used {
        let color: RGBA
        let key: Int
        var count: Int
    }

    @ObservationIgnored private var colorsOn: [UUID: (node: Node, used: [Used])] = [:]

    private func countColors() -> [RGBA] {
        var counts: [Int: Int] = [:]
        var order: [Used] = []
        var kept: [UUID: (node: Node, used: [Used])] = [:]
        for top in doc.nodes {
            let used = colorsOn[top.id].flatMap { $0.node == top ? $0.used : nil } ?? Self.colors(in: top)
            kept[top.id] = (top, used)
            for u in used {
                if counts[u.key] == nil { order.append(u) }
                counts[u.key, default: 0] += u.count
            }
        }
        colorsOn = kept
        return order.enumerated().sorted { a, b in
            let (ca, cb) = (counts[a.element.key] ?? 0, counts[b.element.key] ?? 0)
            return ca != cb ? ca > cb : a.offset < b.offset
        }.map(\.element.color)
    }

    /// The fill and border colours in a layer and all it holds, without their transparency, told
    /// apart as their hex codes are.
    private static func colors(in top: Node) -> [Used] {
        var at: [Int: Int] = [:]
        var used: [Used] = []
        func byte(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        func visit(_ n: Node) {
            for c in [n.fill.on && n.kind != .artboard ? n.fill.color : nil, n.border.on ? n.border.color : nil] {
                guard let c else { continue }
                let key = byte(c.r) << 16 | byte(c.g) << 8 | byte(c.b)
                if let i = at[key] { used[i].count += 1 } else {
                    at[key] = used.count
                    used.append(Used(color: c.with(alpha: 1), key: key, count: 1))
                }
            }
            for child in n.children { visit(child) }
        }
        visit(top)
        return used
    }

    // MARK: Saving

    func scheduleSave(after milliseconds: Int = 600) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        saveTask?.cancel()
        saveTask = nil
        var copy = doc
        copy.viewport = viewport
        let url = url
        Self.saving.async {
            do {
                try DesignFile.write(copy, to: url)
            } catch {
                NSLog("Bezzle could not save %@: %@", url.path, error.localizedDescription)
            }
        }
        Library.shared.touched(url)
    }

    /// Saving happens on a queue of its own, one save after another, so writing a large design
    /// does not hold the app up.
    private static let saving = DispatchQueue(label: "com.erik.Bezzle.saving", qos: .userInitiated)

    /// Waits until every save asked for so far is on disk.
    static func finishSaving() {
        saving.sync {}
    }

    /// Gives the design a new name, renaming its file.
    func rename(to newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty, clean != name else { return }
        save()
        Self.finishSaving()
        let target = Library.shared.freeURL(named: clean, in: url.deletingLastPathComponent())
        do {
            try FileManager.default.moveItem(at: url, to: target)
            Library.shared.renamed(from: url, to: target)
            url = target
            assets = Assets(design: target)
        } catch {
            NSLog("Bezzle could not rename %@: %@", url.path, error.localizedDescription)
        }
    }

    // MARK: Reading

    var selectedNodes: [Node] { selection.compactMap { doc.node($0) } }

    func node(_ id: UUID) -> Node? { doc.node(id) }

    /// The selection's outline on the canvas: around what is drawn, turned layers included.
    var selectionBounds: CGRect? {
        var bounds: CGRect?
        for id in selection {
            guard let n = doc.node(id) else { continue }
            let o = doc.parentOrigin(of: id)
            let r = Geometry.bounds(of: n).offsetBy(dx: o.x, dy: o.y)
            bounds = bounds?.union(r) ?? r
        }
        return bounds
    }

    /// The artboard a new layer should go on: the one being looked at most, or the one the
    /// selection is on.
    var focusedArtboard: Node? {
        if let first = selection.first {
            if let n = doc.node(first), n.isArtboard { return n }
            if let board = doc.artboard(of: first) { return board }
        }
        let visible = visibleCanvasRect
        return doc.artboards.max { a, b in
            a.frame.intersection(visible).area < b.frame.intersection(visible).area
        }.flatMap { $0.frame.intersects(visible) ? $0 : nil }
    }

    var visibleCanvasRect: CGRect {
        CGRect(origin: viewport.origin, size: CGSize(width: canvasSize.width / viewport.zoom, height: canvasSize.height / viewport.zoom))
    }
}

extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
