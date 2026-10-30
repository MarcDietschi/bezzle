import AppKit
import Observation

enum Tool: String, CaseIterable {
    case select, artboard, rectangle, ellipse, line, pen, knife, text

    var title: String {
        switch self {
        case .select: String(localized: "Select")
        case .artboard: String(localized: "Artboard")
        case .rectangle: String(localized: "Rectangle")
        case .ellipse: String(localized: "Ellipse")
        case .line: String(localized: "Line")
        case .pen: String(localized: "Pen")
        case .knife: String(localized: "Knife")
        case .text: String(localized: "Text")
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
        case .knife: "K"
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
    /// The design as it is seen, each deck showing the post in front (`seenDoc`).
    @ObservationIgnored var seenWorkedOut: (version: Int, fronts: [UUID: Int], doc: BezzleDocument)?
    var selection: [UUID] = [] {
        didSet { if selection != oldValue { selectionChanged() } }
    }
    var tool: Tool = .select {
        didSet {
            guard tool != oldValue else { return }
            // The pen works on the points being edited; any other drawing tool leaves them.
            if tool != .select && tool != .pen { editingPath = nil }
            if tool != .select { editingPicture = nil; building = nil }
            guides = []
        }
    }
    var viewport = Viewport() {
        // Where the design was looked at is kept too, but there is no hurry about it.
        didSet { if viewport != oldValue { scheduleSave(after: 2000) } }
    }
    /// The post each deck shows, by its number, where it is not the first: here alone, so that
    /// everyone sharing a design turns through its decks as they like. See `Deck`.
    var fronts: [UUID: Int] = [:]
    /// What is offered for a moment after a change to a deck. See `DeckOffer`.
    var offer: DeckOffer?
    /// Each deck's posts that something no longer fits on, as the deck was when they were found.
    @ObservationIgnored var brokenWorkedOut: [UUID: (node: Node, posts: Set<Int>)] = [:]
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
        didSet {
            guard editingPath != oldValue else { return }
            selectedPoints = []
            if editingPath != openedShape?.id { closeShape() }
            if editingPath != nil { editingPicture = nil }
        }
    }
    /// The layer whose picture is being moved and resized inside it, shown whole on the canvas.
    var editingPicture: UUID?
    /// Layers whose picture is having its background taken away just now, and how far it has got.
    /// See `removeBackground`.
    var cuttingOut: [UUID: CutoutWork] = [:]
    /// Why a background could not be taken away, shown for a moment.
    var cutoutTrouble: LocalizedStringResource?
    /// A rectangle, ellipse or line whose points are being edited: a path until they are left,
    /// and then the shape again unless its outline was changed. What it was, and what it became.
    @ObservationIgnored private var openedShape: (id: UUID, shape: Node, path: Node)?
    /// The points picked out on it.
    var selectedPoints: Set<PathPoint> = []
    /// The shapes being built with: the canvas shows the pieces they cut each other into, to be
    /// joined or wiped away. See `startBuilding`.
    var building: [UUID]? {
        didSet { if building != nil { editingPath = nil; editingPicture = nil } }
    }
    @ObservationIgnored var piecesWorkedOut: (version: Int, ids: [UUID], pieces: [Outlines.Piece])?
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
    /// What bringing the design in from another app could only approximate, shown until read.
    var importReport: ImportReport?
    /// Set while the design is shared through iCloud.
    var sharing: Collaboration?

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
        var document = try DesignFile.read(url)
        // A shared design opens as it is shared, which its own file may lag behind.
        let sharing = Collaboration.open(url)
        if let sharing {
            let viewport = document.viewport
            document = sharing.document()
            document.viewport = viewport
        }
        self.init(url: url, document: document)
        if let sharing {
            self.sharing = sharing
            sharing.attach(to: self)
        }
    }

    /// The design's pictures, read from its package as they are drawn.
    @ObservationIgnored private(set) var assets: Assets

    var name: String { url.deletingPathExtension().lastPathComponent }

    // MARK: Changing the document

    /// Changes the document as one step of the undo history, named for the Edit menu. Inside a
    /// gesture the change is folded into the gesture's one step.
    func edit(_ action: LocalizedStringResource, _ change: (inout BezzleDocument) -> Void) {
        guard !isReadOnly else { return }
        let before = Snapshot(doc: doc, selection: selection)
        var next = doc
        change(&next)
        next.syncGrids(since: doc, start: gestureStart?.doc)
        next.syncDecks(since: doc, fronts: fronts)
        next.fitGroups(since: doc)
        next.fitCarousels()
        guard next != doc else { return }
        doc = next
        if gestureStart == nil {
            record(before, action)
            considerOffer(after: before.doc)
        }
        scheduleSave()
    }

    /// Starts a drag, a scrub or anything else made of many small changes that undo as one.
    func beginGesture() {
        if gestureStart == nil { gestureStart = Snapshot(doc: doc, selection: selection) }
    }

    func endGesture(_ action: LocalizedStringResource) {
        guard let start = gestureStart else { return }
        gestureStart = nil
        // Cells held apart while something in one of them was dragged settle where they go.
        var settled = doc
        settled.relayoutGrids(since: start.doc)
        settled.fitGroups(since: doc)
        if settled != doc { doc = settled }
        if start.doc != doc {
            record(start, action)
            considerOffer(after: start.doc)
        }
        guides = []
        measurement = nil
        sharing?.showIfIdle()
    }

    /// Puts everything back as it was when the gesture started (Escape during a drag).
    func cancelGesture() {
        guard let start = gestureStart else { return }
        gestureStart = nil
        doc = start.doc
        selection = start.selection
        guides = []
        measurement = nil
        sharing?.showIfIdle()
    }

    var inGesture: Bool { gestureStart != nil }

    private func record(_ before: Snapshot, _ action: LocalizedStringResource) {
        guard let undoManager else { return }
        // The history never sees an opened shape become a path: undoing the first change to its
        // outline goes back to the shape.
        let before = Snapshot(doc: withShapeBack(before.doc), selection: before.selection)
        let after = withShapeBack(doc)
        undoManager.registerUndo(withTarget: self) { store in
            let now = Snapshot(doc: store.withShapeBack(store.doc), selection: store.selection)
            // Others sharing the design may have changed it since: only what this step did is
            // taken back, and their changes stay.
            store.doc = now.doc == after ? before.doc : FlatDesign.apply(from: after, to: before.doc, onto: now.doc)
            store.selection = before.selection.filter { store.doc.path(of: $0) != nil }
            store.editingText = nil
            if let id = store.editingPath, store.node(id)?.kind != .path { store.editingPath = nil }
            store.record(now, action)
            store.scheduleSave()
        }
        undoManager.setActionName(String(localized: action))
    }

    private func selectionChanged() {
        if let editing = editingText, !selection.contains(editing) { editingText = nil }
        if let editing = editingPath, selection != [editing] { editingPath = nil }
        if let editing = editingPicture, selection != [editing] { editingPicture = nil }
        if let shapes = building, Set(shapes) != Set(selection) { building = nil }
        if let offer, !selection.contains(offer.anchor) { self.offer = nil }
        // A layer of a deck's post that is not in front brings that post to the front; one of the
        // design behind the posts is the same layer in the post in front.
        if let first = selection.first, let (deck, post) = doc.post(of: first) {
            if let post, post != front(of: deck) {
                fronts[deck.id] = post
            } else if post == nil, let front = front(of: deck) {
                selection = selection.map { id in doc.post(of: id)?.post == nil && doc.post(of: id) != nil ? id.mixed(Deck.key(front)) : id }
            }
        }
        preview = nil
    }

    // MARK: Shapes opened as paths

    /// Starts editing the points of a rectangle, ellipse or line, which is a path while they are
    /// edited. Left as it was, it is the shape again.
    func editAsPath(_ id: UUID) {
        guard let shape = node(id), !shape.locked, let path = shape.asPath() else { return }
        selection = [id]
        doc.update(id) { $0 = path }
        openedShape = (id, shape, path)
        editingPath = id
    }

    /// `doc` with the opened shape in it, if its outline is still the one it was opened with.
    private func withShapeBack(_ doc: BezzleDocument) -> BezzleDocument {
        guard let (id, shape, path) = openedShape, let n = doc.node(id), n.kind == .path,
              n.path == path.path, n.pathBox == path.pathBox else { return doc }
        var back = doc
        back.update(id) { $0 = $0.asShape(shape) }
        return back
    }

    private func closeShape() {
        let back = withShapeBack(doc)
        openedShape = nil
        if back != doc { doc = back }
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
        var regrown = false
        for id in preview.ids {
            shown.update(id) { node in
                preview.change(&node)
                node.refit()
                // A grid shown with more cells or fewer has them.
                if node.isRepeatGrid {
                    RepeatGrid.heal(&node)
                    regrown = true
                }
            }
        }
        if regrown { shown.fitGroups() }
        return shown
    }

    /// The colours the design uses, the most used first, without their transparency.
    var designColors: [RGBA] {
        if let worked = colorsWorkedOut, worked.version == version { return worked.colors }
        let colors = countColors()
        colorsWorkedOut = (version, colors)
        return colors
    }

    /// How many layers there are, as they are seen: of a deck, the post in front.
    var layerCount: Int {
        if doc.nodes.contains(where: \.isDeck) { return seenDoc.layerCount }
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
        var copy = withShapeBack(doc)
        // Saved for where it was looked at alone, the design has nothing new for sharing to take
        // in, and taking in a large one again holds the canvas up just as moving about resumes.
        if let sharing {
            let now = TakenIn(version: version, sharing: ObjectIdentifier(sharing), opened: openedShape?.id)
            if takenIn != now {
                sharing.takeIn(copy)
                takenIn = now
            }
            sharing.persist()
        }
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

    /// What the last save gave sharing to take in: the design as it was then, and which sharing.
    private struct TakenIn: Equatable {
        let version: Int
        let sharing: ObjectIdentifier
        let opened: UUID?
    }
    @ObservationIgnored private var takenIn: TakenIn?

    /// Saving happens on a queue of its own, one save after another, so writing a large design
    /// does not hold the app up.
    static let saving = DispatchQueue(label: "com.erik.Bezzle.saving", qos: .userInitiated)

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
            sharing?.moved(to: target)
        } catch {
            NSLog("Bezzle could not rename %@: %@", url.path, error.localizedDescription)
        }
    }

    // MARK: Sharing

    /// The design as the others see it: an opened shape is still the shape.
    var sharedDoc: BezzleDocument { withShapeBack(doc) }

    /// Whether it can only be looked at: someone else's design this Mac no longer shares.
    var isReadOnly: Bool { sharing?.mark == .ended }

    /// Makes a design of its own from this one as it is now, beside the others in the Bezzle
    /// folder, and opens it. For a design someone shared, it is how to keep one of one's own.
    func saveCopy() {
        save()
        Self.finishSaving()
        var copy = withShapeBack(doc)
        copy.viewport = viewport
        let target = Library.shared.freeURL(named: String(localized: "\(name) copy"), in: Library.shared.folder)
        do {
            try DesignFile.write(copy, to: target)
            if let images = assets.folder, FileManager.default.fileExists(atPath: images.path) {
                let into = target.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
                try? FileManager.default.removeItem(at: into)
                try FileManager.default.copyItem(at: images, to: into)
            }
        } catch {
            NSLog("Bezzle could not save a copy of %@: %@", url.path, error.localizedDescription)
            return
        }
        Library.shared.touched(target)
        WindowRouter.shared.open(target)
    }

    /// Shows the design with what others changed: `next` holds everything done here as well.
    /// It is not a step of the undo history, and undoing afterwards leaves it in place.
    func showChangesFromOthers(_ next: BezzleDocument) {
        var next = next
        let old = doc
        next.viewport = old.viewport
        // A shape whose points are being edited is a path here; it stays one, unless someone
        // else changed it meanwhile.
        if let opened = openedShape {
            if let mine = old.node(opened.id), next.node(opened.id) == withShapeBack(old).node(opened.id) {
                next.update(opened.id) { $0 = mine }
            } else {
                openedShape = nil
                editingPath = nil
            }
        }
        // Artboards nobody changed stay as they were, sharing their storage, so what is worked
        // out from them is not worked out again.
        var kept: [UUID: Node] = [:]
        for n in old.nodes { kept[n.id] = n }
        next.nodes = next.nodes.map { n in kept[n.id].flatMap { $0 == n ? $0 : nil } ?? n }
        guard next != old else { return }
        if var start = gestureStart {
            start.doc = FlatDesign.apply(from: old, to: next, onto: start.doc)
            gestureStart = start
        }
        doc = next
        let gone = selection.filter { next.path(of: $0) == nil }
        if !gone.isEmpty { selection.removeAll { gone.contains($0) } }
        if let id = hovered, next.path(of: id) == nil { hovered = nil }
        if let id = editingPicture, next.node(id) == nil { editingPicture = nil }
        if let id = editingPath, next.node(id)?.kind != .path { editingPath = nil }
        if !selectedPoints.isEmpty, let id = editingPath, old.node(id)?.path != next.node(id)?.path { selectedPoints = [] }
        canvas?.syncEditor()
        scheduleSave()
    }

    /// A design that was one file becomes a package, which pictures and sharing need.
    func becamePackage() {
        assets = Assets(design: url)
    }

    /// A picture someone else added has come from iCloud.
    func pictureArrived(_ name: String) {
        assets.arrived(name)
        canvas?.tiles.forget()
        canvas?.needsDisplay = true
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
