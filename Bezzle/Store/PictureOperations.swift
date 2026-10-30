import Foundation

/// Placing a picture inside the layer it fills: see `PictureTool`.
extension DocumentStore {
    /// Whether the one layer selected has a picture that can be placed inside it.
    var canEditPicture: Bool {
        guard selection.count == 1, let n = node(selection[0]) else { return false }
        return !n.isArtboard && !n.locked && n.fill.on && n.fill.image != nil
    }

    /// Starts placing the selected layer's picture inside it.
    func editPicture() {
        guard canEditPicture else { return }
        tool = .select
        editingPath = nil
        editingPicture = selection[0]
    }
}
