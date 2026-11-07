import AppKit
import Observation

/// Which of the drawing aids the canvas shows: the rulers, the guides and the layout grids. They
/// are the same in every window and kept from one launch to the next. What is hidden is not
/// caught on either: what shows is what snaps.
@MainActor @Observable
final class Helpers {
    static let shared = Helpers()

    var rulers: Bool { didSet { defaults.set(rulers, forKey: "helpers.rulers") } }
    var guides: Bool { didSet { defaults.set(guides, forKey: "helpers.guides") } }
    var grids: Bool { didSet { defaults.set(grids, forKey: "helpers.grids") } }
    /// Guides stay where they are, and the pointer goes through them to what lies under.
    var guidesLocked: Bool { didSet { defaults.set(guidesLocked, forKey: "helpers.guidesLocked") } }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        let d = UserDefaults.standard
        rulers = d.object(forKey: "helpers.rulers") as? Bool ?? true
        guides = d.object(forKey: "helpers.guides") as? Bool ?? true
        grids = d.object(forKey: "helpers.grids") as? Bool ?? true
        guidesLocked = d.bool(forKey: "helpers.guidesLocked")
    }

    /// The entries of the menus that show and hide them, for the zoom menu and the rulers' corner.
    func entries(for store: DocumentStore) -> [MenuEntry] {
        let board = store.focusedArtboard
        let guides = board?.guides?.count ?? 0
        return [
            .item("Rulers", shortcut: "⌃R", checked: rulers) { self.rulers.toggle() },
            .item("Guides", shortcut: "⌃,", checked: self.guides) { self.guides.toggle() },
            .item("Layout Grids", shortcut: "⌃G", checked: grids) { self.grids.toggle() },
            .separator,
            .item("Lock Guides", checked: guidesLocked) { self.guidesLocked.toggle() },
            .item("Remove Guides", enabled: guides > 0 && !store.isReadOnly) {
                if let board { store.removeGuides(from: board.id) }
            },
        ]
    }
}

extension DocumentStore {
    // MARK: Layout grids

    /// Changes an artboard's layout grid: as one step of the history, or as part of a drag going on.
    /// What is changed is kept within what can be had, and a grid left with nothing in it goes.
    func changeLayout(of board: UUID, _ action: LocalizedStringResource, _ change: @escaping (inout LayoutGrid) -> Void) {
        edit(action) { $0.changeLayout(of: board, change) }
    }

    nonisolated static func changeLayout(of node: inout Node, _ change: (inout LayoutGrid) -> Void) {
        node.changeLayout(change)
    }

    /// Gives an artboard the columns that suit its size, and shows layout grids if they were hidden.
    func addLayout(to board: UUID) {
        guard node(board)?.isArtboard == true else { return }
        edit("Add Layout Grid") { $0.addLayout(to: board) }
        Helpers.shared.grids = true
    }

    func removeLayout(from board: UUID) {
        edit("Remove Layout Grid") { $0.removeLayout(from: board) }
    }

    /// The layout grid of the artboard a layer lies on, and that artboard, when grids are shown.
    func shownLayout(of board: Node) -> LayoutGrid? {
        Helpers.shared.grids ? board.layout : nil
    }

    // MARK: Guides

    /// Puts a guide on an artboard, at a place across it (`vertical`) or down it, and returns its key.
    @discardableResult
    func addGuide(at position: CGFloat, vertical: Bool, to board: UUID, _ action: LocalizedStringResource = "Add Guide") -> String? {
        guard let node = node(board), node.isArtboard else { return nil }
        var key: String?
        edit(action) { key = $0.addGuide(at: position, vertical: vertical, to: board) }
        Helpers.shared.guides = true
        return key.flatMap { self.node(board)?.guides?[$0] != nil ? $0 : nil }
    }

    /// Puts a guide somewhere else on its artboard, kept to the edge it is nearer now.
    func moveGuide(_ key: String, on board: UUID, to position: CGFloat, _ action: LocalizedStringResource = "Move Guide") {
        guard let node = node(board), let guide = node.guides?[key],
              Guideline.at(position, vertical: guide.vertical, in: node.frame.size) != guide else { return }
        edit(action) { $0.moveGuide(key, on: board, to: position) }
    }

    func removeGuide(_ key: String, from board: UUID, _ action: LocalizedStringResource = "Remove Guide") {
        guard node(board)?.guides?[key] != nil else { return }
        edit(action) { $0.removeGuide(key, from: board) }
    }

    func removeGuides(from board: UUID) {
        guard node(board)?.guides?.isEmpty == false else { return }
        edit("Remove Guides") { $0.removeGuides(from: board) }
    }

    /// Guides for an artboard where its layout grid's columns, or rows, start and end: the margins,
    /// as lines to keep to once the grid is out of sight.
    func addGuidesAtMargins(of board: UUID) {
        let fresh = doc.guidesAtMargins(of: board)
        guard !fresh.isEmpty else { return }
        edit("Add Guides") { $0.addGuides(fresh, to: board) }
        Helpers.shared.guides = true
    }
}
