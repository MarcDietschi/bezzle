import AppKit
import Observation

enum Tool: String, CaseIterable {
    case select, artboard, rectangle, ellipse, line, pen, knife, text, note

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
        case .note: String(localized: "Note")
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
        case .note: "N"
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
    /// For a gap as wide as another, rather than edges lined up: the space between the two sides
    /// facing across it, which the canvas fills, `from` and `to` running across its middle.
    var field: CGRect? = nil
    /// Whether the gap is beside what is being moved, rather than one it is as wide as.
    var mine = false

    var gap: Bool { field != nil }
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
            versions.presentChanged()
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
    /// The design as a preview that changes more than layers shows it (`Preview.reshape`).
    @ObservationIgnored private var reshapedWorkedOut: (version: Int, token: UUID, doc: BezzleDocument)?
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
            // The inspector offers the artboard sizes to draw while nothing is selected.
            if tool == .artboard { selection = [] }
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
    /// What is offered for a moment after a change to a copy of a component. See `ComponentOffer`.
    var componentOffer: ComponentOffer?
    /// The design seen as a prototype, its screens and the flows between them, rather than as the
    /// layers to draw: the header's switch. Here alone, as the zoom is. See `Flow`.
    var prototyping = false {
        didSet { if prototyping != oldValue { prototypingChanged() } }
    }
    /// The design inspected, as someone building it reads it: measured on the canvas, its specs
    /// and code in the inspector, nothing in it changed. On the prototype's table, so seen as a
    /// prototype too: the header's switch. Here alone. See `InspectTool`.
    var inspecting = false {
        didSet { if inspecting != oldValue { inspectingChanged() } }
    }
    /// The prototype being played, over the design. See `Player`.
    var player: Player?
    /// The flow whose note is being written on its thread, and where on the canvas the thread's
    /// middle is, in the canvas view's points.
    var writingNote: (source: UUID, at: CGPoint)?
    /// A screen the pointer is on in the inspector's list of screens, for the canvas to show the
    /// thread the selected layers would take to it.
    var flowPreview: UUID?
    /// What the last change did to copies of components, and when, for the canvas to show the
    /// other copies following. See `ComponentTool`.
    @ObservationIgnored var componentEcho: (echo: ComponentEcho, at: CFTimeInterval, was: BezzleDocument?)?
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
    /// The letters picked out in the text being typed into, in UTF-16 as the editor counts them;
    /// of no length when there is only the caret. The text card and its colour change these.
    var typingSelection = NSRange(location: 0, length: 0)
    /// Changes how the letters picked out in the text being typed into look, or with only the
    /// caret what is typed next, through the editor so that Undo while typing takes it back. Set
    /// while typing. See `restyleLetters`.
    @ObservationIgnored var restyleTyped: ((LocalizedStringResource, (inout Letters) -> Void) -> Void)?
    /// Words being looked for in the design, or misspelt ones, while the find bar is open.
    var finder: TextFinder?
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
    var showsLayers = true {
        didSet { if showsLayers && showsResources { showsResources = false } }
    }
    /// Whether the resources panel (kits of ready-made parts, and icons) is out, in the layers list's place.
    var showsResources = false {
        didSet { if showsResources && showsLayers { showsLayers = false } }
    }
    /// Whether the layers list was out when the resources panel came, to come back when it goes.
    @ObservationIgnored var layersBeforeResources = true
    /// The size of the canvas on screen, for zooming from the menus.
    var canvasSize: CGSize = .zero
    /// The last artboard size added from the presets, so a new artboard matches the others.
    var lastPreset: CGSize?
    /// A change shown on the canvas but not made: what a preset under the pointer would do.
    var preview: Preview?
    /// The inspector's card that is open, and the one the pointer is on, whose part of the
    /// selected layers the canvas outlines. See `AspectCard`.
    var openAspect: Aspect?
    var pointedAspect: Aspect?
    /// What the Photo card works on while it is open: the pictures' light, colour or detail,
    /// and of their colours, the one picked. A drag on the picture works on the same.
    var developGroup: Develop.Group = .light
    var developBand: Develop.Band?
    /// The tone or colour the pointer is on, on a picture, for the card to light up the same.
    var developPointed: Develop.Isolation?
    /// Whether the picture itself is the control, as the Photo card's target button turns on:
    /// else a press on it moves it, as on any layer. See `DevelopTool`.
    var developOnPhoto = false
    /// What developing would suit each picture best, by the picture, and the glide to it going on.
    @ObservationIgnored var autoKept: [String: Develop] = [:]
    @ObservationIgnored var gliding: Task<Void, Never>?

    struct Preview {
        /// Which control shows it, so only that control takes it away again.
        let key: String
        let ids: [UUID]
        let change: (inout Node) -> Void
        /// A change to more than the layers themselves, such as putting them into a mask.
        var reshape: ((inout BezzleDocument) -> Void)? = nil
        /// Each one shown is a new one, even from the same control, such as the next colour
        /// along, so the canvas can ease from one to the next.
        let token = UUID()
    }

    private(set) var url: URL
    /// Leads to the design's file wherever it goes on this disk, to find it again should it be
    /// renamed or moved while open; see `follow`.
    @ObservationIgnored private var bookmark: Data?
    /// Set by the window; Undo and Redo in the Edit menu use it.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// Watched, so the inspector can lift the card a drag changes for as long as it goes on.
    private var gestureStart: Snapshot?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The canvas on screen, for starting to type into a text layer from elsewhere.
    @ObservationIgnored weak var canvas: CanvasView?
    /// Whether the export panel is showing.
    var exporting = false
    /// What bringing the design in from another app could only approximate, shown until read.
    var importReport: ImportReport?
    /// Set while the design is shared through iCloud.
    var sharing: Collaboration?
    /// A note being written in the margin, not yet posted. See `MarginNote`.
    var draftNote: MarginNote?
    /// The thread open in the margin, to read and answer.
    var openThread: UUID?
    /// The loop being drawn round part of the design with the note tool, on the canvas.
    var noteCircle: CGRect?
    /// Where the typing should go in the note open, asked for from a note's menu.
    var noteFocus: NoteFocus?
    /// When each thread was last read on this Mac, to tell what is new in it.
    @ObservationIgnored lazy var notesSeen = NotesSeen(key: url.standardizedFileURL.path)
    /// The view flying to a note.
    @ObservationIgnored lazy var glide = CanvasGlide()
    /// The design's versions, and looking back through them. See `VersionShelf`.
    let versions = VersionShelf()
    /// What the canvas shows of the design's named looks. See `Style`.
    let styleShow = StyleShow()

    private struct Snapshot {
        var doc: BezzleDocument
        var selection: [UUID]
        /// Which post each deck showed: undone or redone, a deck the step changed shows it again.
        var fronts: [UUID: Int] = [:]
    }

    init(url: URL, document: BezzleDocument) {
        self.url = url
        self.doc = document
        bookmark = Self.bookmark(of: url)
        assets = Assets(design: url)
        if let v = document.viewport { viewport = v }
        versions.attach(self)
        if DesignPreview.exists(for: url) { previewed = version }
    }

    convenience init(opening url: URL) throws {
        // A design once shared through iCloud is first kept as it was last shared.
        SharingFiles.leaveICloud(url)
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
        // Looking back, a change made here brings the design as it is now back into view.
        versions.cameBack()
        let before = Snapshot(doc: doc, selection: selection, fronts: fronts)
        var next = doc
        change(&next)
        next.syncGrids(since: doc, start: gestureStart?.doc)
        next.syncDecks(since: doc, fronts: fronts)
        let echo = next.syncComponents(since: doc, start: gestureStart?.doc)
        next.syncStyles(since: doc)
        next.keepMasks(since: doc)
        next.keepNotes(since: doc)
        next.fitGroups(since: doc)
        next.fitCarousels()
        guard next != doc else { return }
        doc = next
        noteEcho(echo, was: gestureStart == nil ? before.doc : nil)
        if gestureStart == nil {
            record(before, action)
            considerOffer(after: before.doc)
            considerComponentOffer(after: before.doc, echo: echo, action: action)
        }
        noteStyles(after: before.doc, settled: gestureStart == nil)
        scheduleSave()
    }

    /// Starts a drag, a scrub or anything else made of many small changes that undo as one.
    func beginGesture() {
        if gestureStart == nil { gestureStart = Snapshot(doc: doc, selection: selection, fronts: fronts) }
    }

    func endGesture(_ action: LocalizedStringResource) {
        guard let start = gestureStart else { return }
        gestureStart = nil
        // Cells held apart while something in one of them was dragged settle where they go.
        var settled = doc
        settled.relayoutGrids(since: start.doc)
        // Copies among the cells laid out again are made again from their components.
        settled.remakeCopies(since: doc)
        settled.fitGroups(since: doc)
        if settled != doc { doc = settled }
        if start.doc != doc {
            record(start, action)
            considerOffer(after: start.doc)
        }
        noteStyles(after: start.doc, settled: true, dragged: true)
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

    /// The design as the drag going on began, to tell what it has changed so far.
    var gestureBefore: BezzleDocument? { gestureStart?.doc }

    private func record(_ before: Snapshot, _ action: LocalizedStringResource) {
        guard let undoManager else { return }
        // The history never sees an opened shape become a path: undoing the first change to its
        // outline goes back to the shape.
        let before = Snapshot(doc: withShapeBack(before.doc), selection: before.selection, fronts: before.fronts)
        let after = withShapeBack(doc)
        undoManager.registerUndo(withTarget: self) { store in
            store.versions.cameBack()
            let now = Snapshot(doc: store.withShapeBack(store.doc), selection: store.selection, fronts: store.fronts)
            // Others sharing the design may have changed it since: only what this step did is
            // taken back, and their changes stay.
            store.doc = now.doc == after ? before.doc : FlatDesign.apply(from: after, to: before.doc, onto: now.doc)
            // A deck the step changed shows the post it showed then: undoing a post added or taken
            // away shows the one that was in front, not whichever happens to be first.
            for id in Self.decks(changedFrom: before.doc, to: after) { store.fronts[id] = before.fronts[id] }
            store.selection = before.selection.filter { store.doc.path(of: $0) != nil }
            store.editingText = nil
            if let id = store.editingPath, store.node(id)?.kind != .path { store.editingPath = nil }
            store.record(now, action)
            store.scheduleSave()
        }
        undoManager.setActionName(String(localized: action))
    }

    /// The decks that are not the same in two designs, or are a deck in only one of them.
    private static func decks(changedFrom a: BezzleDocument, to b: BezzleDocument) -> [UUID] {
        var was: [UUID: Node] = [:]
        for n in a.nodes where n.isDeck { was[n.id] = n }
        var changed: [UUID] = []
        for n in b.nodes {
            if let then = was.removeValue(forKey: n.id) {
                if then != n { changed.append(n.id) }
            } else if n.isDeck {
                changed.append(n.id)
            }
        }
        return changed + was.keys
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
        doc = changing(id, to: path, in: doc)
        openedShape = (id, shape, path)
        editingPath = id
    }

    /// `doc` with the opened shape in it, if its outline is still the one it was opened with.
    private func withShapeBack(_ doc: BezzleDocument) -> BezzleDocument {
        guard let (id, shape, path) = openedShape, let n = doc.node(id), n.kind == .path,
              n.path == path.path, n.pathBox == path.pathBox else { return doc }
        return changing(id, to: n.asShape(shape), in: doc)
    }

    /// `doc` with a layer opened as a path or made the shape again, and with it the same layer in
    /// the other cells of a repeat grid or the other posts of a deck. Neither is a step of the
    /// history, but the copies must follow all the same: a change carried over from a copy left
    /// a shape would make the layer a shape again everywhere.
    private func changing(_ id: UUID, to node: Node, in doc: BezzleDocument) -> BezzleDocument {
        var next = doc
        next.update(id) { $0 = node }
        next.syncGrids(since: doc)
        next.syncDecks(since: doc, fronts: fronts)
        next.syncComponents(since: doc)
        return next
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

    /// Shows a change to the design as a whole on the canvas without making it, such as a mask
    /// being made; with nil, takes away the preview `key` showed.
    func showPreview(_ key: String, reshaping reshape: ((inout BezzleDocument) -> Void)?) {
        if let reshape {
            preview = Preview(key: key, ids: [], change: { _ in }, reshape: reshape)
        } else if preview?.key == key {
            preview = nil
        }
    }

    /// The document as the canvas shows it: with the preview, if there is one.
    var shownDoc: BezzleDocument {
        guard let preview else { return doc }
        var shown = doc
        if let reshape = preview.reshape {
            // Asked for every frame the canvas draws: made once for each design and preview.
            if let worked = reshapedWorkedOut, worked.version == version, worked.token == preview.token { return worked.doc }
            reshape(&shown)
            shown.keepMasks(since: doc)
            shown.fitGroups(since: doc)
            reshapedWorkedOut = (version, preview.token, shown)
            return shown
        }
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
            for c in (n.kind != .artboard ? n.fills.map(\.color) : []) + n.borders.map(\.color) {
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
        follow()
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
        // Nowhere to be found, it is written again where it was, so that nothing done is lost.
        let url = url, creating = !DesignFile.exists(url)
        Self.saving.async { [copy] in
            do {
                try DesignFile.write(copy, to: url, creating: creating)
                Self.unwritten[url] = nil
            } catch is DesignFile.Gone {
                // It went in the moment since: saved again where it went, once found.
                DispatchQueue.main.async { [weak self] in self?.lost(copy, from: url) }
            } catch {
                Self.unwritten[url] = error.localizedDescription
                NSLog("Bezzle could not save %@: %@", url.path, error.localizedDescription)
            }
        }
        Library.shared.touched(url)
        versions.saved(copy)
        schedulePreview()
    }

    // MARK: The Finder's picture

    /// Which change of the design the picture the Finder shows for its file was last made from;
    /// nil while it has none. See `DesignPreview`.
    @ObservationIgnored private var previewed: Int?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    /// The design was saved: if it changed, its picture is made again a little later, once for
    /// however many changes come meanwhile, as making one of a large design takes a moment.
    private func schedulePreview() {
        // Unit tests leave the designs they write as they are.
        guard !BezzleApp.isTesting, previewed != version, previewTask == nil else { return }
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: DesignPreview.every)
            guard !Task.isCancelled else { return }
            self?.makePreview()
        }
    }

    /// Makes the design's picture as it is now, if it changed since the last was made: on closing,
    /// and as Bezzle quits, when `now` draws it before returning.
    func makePreview(now: Bool = false) {
        previewTask?.cancel()
        previewTask = nil
        guard !BezzleApp.isTesting, previewed != version else { return }
        previewed = version
        let doc = sharedDoc, url = url, assets = assets
        if now {
            DesignPreview.write(doc, assets: assets, to: url)
        } else {
            DesignPreview.making.async { DesignPreview.write(doc, assets: assets, to: url) }
        }
    }

    /// Why the last save of each design that could not be written failed. Only ever touched on
    /// the saving queue.
    nonisolated(unsafe) private static var unwritten: [URL: String] = [:]

    /// Of the designs at `urls`, those whose last save did not reach the disk, and why, once every
    /// save asked for so far is done.
    static func unsaved(among urls: [URL]) -> [(url: URL, reason: String)] {
        saving.sync { urls.compactMap { url in unwritten[url].map { (url, $0) } } }
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
    nonisolated static let saving = DispatchQueue(label: "com.erik.Bezzle.saving", qos: .userInitiated)

    /// Waits until every save asked for so far is on disk.
    static func finishSaving() {
        saving.sync {}
    }

    /// Whether the design may be given a new name here: not someone else's, shared with this Mac.
    var mayRename: Bool { sharing?.mark?.renamable ?? true }

    /// Gives the design a new name, renaming its file.
    func rename(to newName: String) {
        guard mayRename, let target = Library.shared.renamedURL(url, to: newName) else { return }
        move(to: target)
    }

    /// Moves the design's file to `target`, on with its work there: for a new name, or into
    /// another designs folder. False when it could not be moved, and it stays where it was.
    @discardableResult
    func move(to target: URL) -> Bool {
        save()
        Self.finishSaving()
        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            NSLog("Bezzle could not move %@ to %@: %@", url.path, target.path, error.localizedDescription)
            return false
        }
        arrived(at: target)
        return true
    }

    /// Finds the design's file again when it is no longer where it was: renamed or moved in the
    /// Finder, or by someone else and brought here by the folder that keeps it in step with
    /// their Mac. The design goes on where its file now is, rather than beginning again where it
    /// was and leaving everyone else's work in the other. True when it was found elsewhere.
    @discardableResult
    func follow() -> Bool {
        guard !DesignFile.exists(url) else {
            // One saved for the first time only now has a file to lead to.
            if bookmark == nil { bookmark = Self.bookmark(of: url) }
            return false
        }
        guard let found = whereNow() else { return false }
        NSLog("Bezzle found %@ again at %@", url.path, found.path)
        arrived(at: found)
        return true
    }

    /// Where the design's file is now: where its bookmark leads, or else, in the folder it was in,
    /// the one shared in the same room. Never one in the Trash, nor a guess between several.
    private func whereNow() -> URL? {
        let old = url.standardizedFileURL
        func usable(_ candidate: URL) -> Bool {
            candidate != old && BezzleDocument.fileExtensions.contains(candidate.pathExtension.lowercased())
                && !candidate.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" } && DesignFile.exists(candidate)
        }
        var stale = false
        if let bookmark, let found = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
            // A bookmark leads to the file by its real path; one renamed where it was keeps the
            // path the design had, as the designs folder knows it.
            let beside = old.deletingLastPathComponent().appendingPathComponent(found.lastPathComponent)
            let found = beside.resolvingSymlinksInPath() == found.resolvingSymlinksInPath() ? beside : found.standardizedFileURL
            if usable(found) { return found }
        }
        let linkRoom = sharing?.link?.keys?.room, folderRoom = sharing?.folder?.room.seed
        guard linkRoom != nil || folderRoom != nil else { return nil }
        let beside = (try? FileManager.default.contentsOfDirectory(at: old.deletingLastPathComponent(), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let same = beside.map(\.standardizedFileURL).filter { candidate in
            guard usable(candidate) else { return false }
            if let linkRoom, SharingFiles.link(of: candidate)?.keys?.room == linkRoom { return true }
            if let folderRoom, FolderSync.room(of: candidate)?.seed == folderRoom { return true }
            return false
        }
        return same.count == 1 ? same[0] : nil
    }

    /// The design's file went while it was being saved. Found again, the design is saved where
    /// it now is; nowhere to be found, it is written again where it was, so that nothing done to
    /// it is lost.
    private func lost(_ copy: BezzleDocument, from old: URL) {
        if url != old || follow() {
            save()
            return
        }
        Self.saving.async {
            do {
                try DesignFile.write(copy, to: old)
                Self.unwritten[old] = nil
            } catch {
                Self.unwritten[old] = error.localizedDescription
                NSLog("Bezzle could not save %@: %@", old.path, error.localizedDescription)
            }
        }
    }

    /// Goes on with the design where its file now is.
    private func arrived(at target: URL) {
        Library.shared.renamed(from: url, to: target)
        url = target
        bookmark = Self.bookmark(of: target)
        assets = Assets(design: target)
        sharing?.moved(to: target)
        // Into a folder Google Drive or the like keeps in step: shared with everyone who has it.
        if sharing == nil, FolderSync.applies(to: target), let session = Collaboration.open(target) {
            _ = session.document()
            sharing = session
            session.attach(to: self)
        }
    }

    private static func bookmark(of url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    // MARK: Sharing

    /// The design as the others see it: an opened shape is still the shape.
    var sharedDoc: BezzleDocument { withShapeBack(doc) }

    /// Whether it can only be looked at: someone else's design this Mac no longer shares.
    var isReadOnly: Bool { sharing?.isReadOnly == true }

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
                next = changing(opened.id, to: mine, in: next)
            } else {
                openedShape = nil
                editingPath = nil
            }
        }
        // A mask whose shape someone else took away while layers were put in it here holds none
        // of them by the first of those, as this Mac alone knows which its shape was.
        next.keepMasks(since: old)
        next.reconcileComponents()
        next.fitGroups(since: old)
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
