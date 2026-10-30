import SwiftUI
import AppKit

/// Puts the canvas into the SwiftUI window, and opens its right-click menus in Bezzle's own style.
struct CanvasHost: NSViewRepresentable {
    let store: DocumentStore
    let menus: MenuHost

    func makeNSView(context: Context) -> CanvasView {
        let view = CanvasView(store: store)
        view.onContextMenu = { point, entries in
            menus.show(at: point, width: 230, entries: entries)
        }
        store.canvas = view
        return view
    }

    func updateNSView(_ view: CanvasView, context: Context) {}
}

/// What a right click on the canvas offers.
enum CanvasMenus {
    static func entries(for store: DocumentStore) -> [MenuEntry] {
        let some = !store.selection.isEmpty
        var entries: [MenuEntry] = []
        if some {
            entries += [
                .item("Cut", shortcut: "⌘X") { store.cutSelection() },
                .item("Copy", shortcut: "⌘C") { store.copySelection() },
                .item("Paste", shortcut: "⌘V", enabled: store.canPaste) { store.paste() },
                .item("Duplicate", shortcut: "⌘D") { store.duplicateSelection() },
                .item("Delete", shortcut: "⌫") { store.deleteSelection() },
                .separator,
                .item("Bring to Front", shortcut: "⇧⌘]") { store.arrange(.front) },
                .item("Bring Forward", shortcut: "⌘]") { store.arrange(.forward) },
                .item("Send Backward", shortcut: "⌘[") { store.arrange(.backward) },
                .item("Send to Back", shortcut: "⇧⌘[") { store.arrange(.back) },
                .separator,
            ]
            let nodes = store.selectedNodes
            let locked = nodes.allSatisfy(\.locked)
            entries.append(.item(locked ? "Unlock" : "Lock", shortcut: "⌘L") { store.setLocked(!locked, store.selection) })
            entries.append(.item("Hide", shortcut: "⇧⌘H") { store.setHidden(true, store.selection) })
            if nodes.count == 1, nodes[0].kind == .path, !nodes[0].locked {
                if store.editingPath == nodes[0].id {
                    entries += [.separator, .item("Done Editing Points", shortcut: "↩") { store.editingPath = nil }]
                } else {
                    entries += [.separator, .item("Edit Points", shortcut: "↩") { store.editPoints() }]
                }
            } else if store.canConvertToPath {
                entries += [.separator, .item("Convert to Path", shortcut: "⌘8") { store.convertToPath() }]
            }
            let exported = nodes.count > 1 ? "\(nodes.count) Layers" : nodes.first?.isArtboard == true ? "Artboard" : nodes.first?.isGroup == true ? "Group" : "Layer"
            entries += [.separator, .item("Export \(exported)…", shortcut: "⌘E") { ExportPanel.present(for: store) }]
        } else {
            entries += [
                .item("Paste", shortcut: "⌘V", enabled: store.canPaste) { store.paste() },
                .item("Select All", shortcut: "⌘A", enabled: !store.doc.nodes.isEmpty) { store.selectAll() },
                .separator,
                .item("Zoom to Fit", shortcut: "⌘0") { store.zoomToFit() },
                .item("Actual Size", shortcut: "⌘1") { store.zoom(to: 1) },
            ]
        }
        return entries
    }
}
