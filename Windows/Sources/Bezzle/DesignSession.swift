import Foundation
import BezzleCore

/// What the parts of a design window share: the tool, what is selected and on which artboard,
/// the zoom. Each part listens and shows it again when it changes (as the Mac's DocumentStore is
/// observed).
@MainActor
final class DesignSession {
    let name: String
    var tool: Glyphs.Tool = .select {
        didSet {
            // The pen works on the points being edited; any other drawing tool leaves them.
            if tool != .select && tool != .pen { pen.editingPath = nil }
            changed()
        }
    }
    /// The pen and a path's points (the shared PenTool): the canvas hands it the pointer, the
    /// Path card shows and sets the points it has picked.
    let pen = WindowsCore.Pen()
    /// Building with the pieces the selected shapes cut each other into (the shared
    /// PieceBuilding): the Arrange card's Build button starts it, the canvas works it.
    let builder = WindowsCore.BuildHand()
    /// The photo as the control, while the Photo card is open with its target on (the Mac's
    /// DevelopTool): the card turns it on, the canvas works it.
    let develop = WindowsCore.DevelopHand()
    /// The design inspected (the Mac's InspectTool): read, never changed.
    let inspect = WindowsCore.InspectHand()
    /// The design as a prototype (the Mac's FlowTool): threads pulled from layers to screens.
    let flow = WindowsCore.FlowHand()
    /// Design, Prototype or Inspect (0, 1, 2), as the bar's switch says.
    var mode = 0 {
        didSet {
            guard mode != oldValue else { return }
            inspect.on = mode == 2
            flow.on = mode == 1
            if mode != 0 { develop.on = false }
            changed()
        }
    }
    /// Plays the prototype from a screen, or from where it starts (the window's player).
    var play: ((UUID?) -> Void)?
    /// A layer brought into sight on the canvas, when it is out of it.
    var reveal: ((UUID) -> Void)?
    /// The Export sheet, opened.
    var openExport: (() -> Void)?
    /// The style pointed at in the inspector: the canvas outlines every layer that uses it.
    var pointedStyle: UUID? { didSet { if pointedStyle != oldValue { for f in styleListeners { f() } } } }
    private var styleListeners: [() -> Void] = []
    func listenToStyles(_ f: @escaping () -> Void) { styleListeners.append(f) }
    /// The Photo card's colour whose rows show, as a press on the photo picks it.
    var pickPhotoBand: ((String) -> Void)?
    /// The selected layers, all on the artboard at `board` (its index among the design's layers);
    /// with none selected, `board` is the artboard whose page the layers list shows, if any.
    private(set) var selection: [UUID] = []
    private(set) var board: Int?
    var zoom = 0.5 { didSet { if zoom != oldValue { changed() } } }
    /// The inspector's open card, which the canvas lights what belongs to it for (a layout grid).
    var openCard: String? { didSet { if openCard != oldValue { openCardChanged?() } } }
    var openCardChanged: (() -> Void)?
    /// Opens a card in the inspector, by its name, as the Mac's store.openAspect is set.
    var showCard: ((String) -> Void)?
    var showsLayers = true { didSet { changed() } }

    /// The layer under the pointer, on the canvas or in the layers list: the canvas outlines it
    /// and the list lights its row, as the Mac's store.hovered. It has listeners of its own, as
    /// it changes with every move of the pointer.
    var hovered: UUID? { didSet { if hovered != oldValue { for f in hoverListeners { f() } } } }
    private var hoverListeners: [() -> Void] = []
    func listenToHover(_ f: @escaping () -> Void) { hoverListeners.append(f) }

    private var listeners: [() -> Void] = []
    /// What wants to know that the design itself changed (an edit, an undo).
    private var editListeners: [(_ board: Int?) -> Void] = []

    init(name: String) { self.name = name }

    func select(_ ids: [UUID], on board: Int?) {
        selection = ids
        pen.selection = ids
        if let editing = pen.editingPath, ids != [editing] { pen.editingPath = nil }
        self.board = board
        changed()
    }

    func listen(_ f: @escaping () -> Void) { listeners.append(f) }
    func listenToEdits(_ f: @escaping (_ board: Int?) -> Void) { editListeners.append(f) }

    func changed() { for f in listeners { f() } }

    /// The design changed on `board` (or anywhere, nil): what shows it draws it again, and it is
    /// saved a moment later, as the Mac saves (DocumentStore.scheduleSave: 600 ms after a change).
    func edited(board: Int?) {
        for f in editListeners { f(board) }
        changed()
        scheduleSave()
    }

    /// A change is shown on `board` that is not made (a font pointed at in a menu): what shows
    /// the design draws it again, and nothing is saved.
    func previewed(board: Int?) {
        for f in editListeners { f(board) }
    }

    /// Asks for a design to open (Ctrl+O).
    var onOpen: (() -> Void)?

    /// Why the design could not be saved, if it could not; shown by the window.
    private(set) var unsaved: String?
    var onUnsaved: ((String?) -> Void)?
    private var saveTimer: Timer?

    func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    func save() {
        saveTimer?.invalidate()
        saveTimer = nil
        do {
            try WindowsCore.save()
            if unsaved != nil { unsaved = nil; onUnsaved?(nil) }
        } catch {
            let why = "\(error)"
            if unsaved != why { unsaved = why; onUnsaved?(why) }
        }
    }

    /// The selected layers as the core describes them.
    var selectedLayers: [WindowsCore.Layer] {
        guard let board else { return [] }
        let layers = WindowsCore.layers(board: board)
        // The artboard itself, selected by its name, is not among what lies on it.
        let artboard = WindowsCore.boardLayer(board)
        return selection.compactMap { id in layers.first { $0.id == id } ?? (artboard?.id == id ? artboard : nil) }
    }
}
