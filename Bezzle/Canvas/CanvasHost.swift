import SwiftUI
import AppKit

/// Puts the canvas into the SwiftUI window, and opens its right-click menus in Bezzle's own style.
struct CanvasHost: NSViewRepresentable {
    let store: DocumentStore
    let menus: MenuHost

    func makeNSView(context: Context) -> CanvasView {
        // The canvas its tab kept while another was in front, tiles and all, or a new one.
        let view = store.canvas ?? CanvasView(store: store)
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
            if store.canGroup { entries.append(.item(DocumentStore.grouping, shortcut: "⌘G") { store.group() }) }
            if store.canUngroup { entries.append(.item("Ungroup", shortcut: "⇧⌘G") { store.ungroup() }) }
            if let plan = store.maskPlan {
                // Pointed at, the canvas shows the mask made.
                entries.append(.item(DocumentStore.masking, shortcut: "⌃⌘M", preview: { on in store.canvas?.maskTool.preview(plan, on) }) {
                    if let tool = store.canvas?.maskTool { tool.commit(plan) } else { store.mask(plan) }
                })
            }
            if let mask = store.selectedMask, !mask.locked {
                if let id = store.selection.first, id != mask.id, id != mask.children.first?.id {
                    entries.append(.item(DocumentStore.takingOut) { store.takeOutOfMask([id]) })
                }
                entries.append(.item(DocumentStore.unmasking, shortcut: "⌃⇧⌘M") { store.releaseMask(mask.id) })
            }
            // Words along a shape's outline, and straight again.
            if store.ridePair != nil { entries.append(.item(DocumentStore.riding) { store.rideSelection() }) }
            if store.canStraighten {
                let riding = store.selectedNodes.contains(where: \.rides)
                entries.append(.item(riding ? DocumentStore.takingOffPath : DocumentStore.straightening) { store.straightenSelection() })
            }
            if store.canGroup || store.canUngroup || store.canMask || store.selectedMask != nil || store.ridePair != nil || store.canStraighten {
                entries.append(.separator)
            }
            let nodes = store.selectedNodes
            let locked = nodes.allSatisfy(\.locked)
            entries.append(.item(locked ? "Unlock" : "Lock", shortcut: "⌘L") { store.setLocked(!locked, store.selection) })
            // Hidden layers can only be picked in the layers list, where this shows them again.
            if nodes.allSatisfy(\.hidden) {
                entries.append(.item("Show") { store.setHidden(false, store.selection) })
            } else {
                entries.append(.item("Hide", shortcut: "⇧⌘H") { store.setHidden(true, store.selection) })
            }
            // Return places a picture, so a path filled with one opens its points from here.
            let picture = store.canEditPicture
            if picture {
                let placing = store.editingPicture == nodes[0].id
                entries += [.separator, .item(placing ? "Done Placing Picture" : "Place Picture", shortcut: "↩") {
                    if placing { store.editingPicture = nil } else { store.editPicture() }
                }]
            }
            if store.canRemoveBackground || store.canRestoreBackground || store.canVectorize {
                if !picture { entries.append(.separator) }
                if store.canRemoveBackground { entries.append(.item("Remove Background") { store.removeBackground() }) }
                if store.canRestoreBackground { entries.append(.item("Restore Background") { store.restoreBackground() }) }
                if store.canVectorize { entries.append(.item(DocumentStore.vectorizing) { store.vectorize() }) }
            }
            if nodes.count == 1, store.vector(of: nodes[0].id) != nil {
                entries += [.separator, .item("Back to Picture") { store.backToPicture(nodes[0].id) }]
            }
            if nodes.count == 1, nodes[0].kind == .path, !nodes[0].locked {
                if store.editingPath == nodes[0].id {
                    entries += [.separator, .item("Done Editing Points", shortcut: "↩") { store.editingPath = nil }]
                } else {
                    entries += [picture ? nil : .separator, .item("Edit Points", shortcut: picture ? nil : "↩") { store.editPoints() }].compactMap { $0 }
                }
            } else if store.canConvertToPath {
                entries += [.separator, .item("Convert to Path", shortcut: "⌘8") { store.convertToPath() }]
            }
            if store.canCombine {
                entries.append(.item(store.building != nil ? "Done Building" : "Build with Pieces", shortcut: "⌥⌘B") {
                    if store.building != nil { store.building = nil } else { store.startBuilding() }
                })
            }
            if store.canOutlineBorders {
                entries.append(.item("Outline Border", shortcut: "⌥⌘O") { store.outlineBorders() })
            }
            if store.canMakeRepeatGrid {
                entries += [.separator, .item("Make Repeat Grid", shortcut: "⌘R") { store.makeRepeatGrid() }]
            } else if let grid = store.selectedGrid {
                entries.append(.separator)
                if let slot = store.slot(of: nodes[0].id), nodes[0].id != grid.id, nodes[0].kind == .text || nodes[0].fill.image != nil {
                    entries.append(.item("Same in Every Cell") { store.sameInEveryCell(nodes[0].id) })
                    entries.append(.item("Shuffle Cells") { store.shuffle(slot, in: grid.id) })
                }
                if nodes[0].id != grid.id { entries.append(.item("Select Grid") { store.selection = [grid.id] }) }
                entries.append(.item("Ungroup Grid", shortcut: "⇧⌘R") { store.ungroupGrid(grid.id) })
            }
            if store.canMakeComponent {
                entries += [.separator, .item("Make Component", shortcut: "⌥⌘K") { store.makeComponent() }]
            } else if let copy = store.selectedCopy, let master = store.master(of: copy), !copy.locked {
                entries.append(.separator)
                // Each variant, the copy turning into it on the canvas while it is highlighted.
                let variants = Components.variants(of: master)
                let current = Components.variant(copy.instance?.variant, of: master)
                if variants.count > 1 {
                    for v in variants {
                        entries.append(.item(.verbatim(Components.name(of: v, in: master)), checked: v == current, preview: { on in
                            guard on, v != current else { store.showPreview("component.menu", reshaping: nil); return }
                            store.showPreview("component.menu", reshaping: { doc in
                                let before = doc
                                doc.update(copy.id) { $0 = Components.switched($0, to: v, in: master) }
                                doc.syncComponents(since: before)
                            })
                        }) {
                            store.showPreview("component.menu", reshaping: nil)
                            store.setVariant(v, for: [copy.id])
                        })
                    }
                }
                entries.append(.item("New Variant") { store.addVariant(from: copy.id) })
                if nodes.count == 1, nodes[0].id != copy.id {
                    if nodes[0].kind == .text || nodes[0].fill.image != nil {
                        entries.append(.item("Same in Every Copy") { store.giveEveryCopy([nodes[0].id], from: copy.id) })
                    }
                    if nodes[0].own?.isEmpty == false {
                        entries.append(.item("Follow the Other Copies") { store.followComponent([nodes[0].id]) })
                    }
                }
                if store.hasOwnLooks(copy) { entries.append(.item("Look Like the Others") { store.resetCopy(copy.id) }) }
                entries.append(.item("Unlink Copy") { store.unlinkComponent([copy.id]) })
            }
            if let board = store.postableBoard {
                entries.append(.separator)
                entries.append(.item("Add Post", shortcut: "⇧⌘P") { store.addPost(to: board.id) })
                if board.isDeck {
                    entries.append(.item("Show All Posts", shortcut: "⌥⌘P") { store.canvas?.deckTool.openSpread(board) })
                    if nodes.count == 1, store.doc.post(of: nodes[0].id)?.post != nil {
                        if nodes[0].kind == .text || nodes[0].fill.image != nil {
                            entries.append(.item("Same in Every Post") { store.giveEveryPost([nodes[0].id]) })
                        }
                        if nodes[0].own?.isEmpty == false {
                            entries.append(.item("Follow the Other Posts") { store.followDesign([nodes[0].id]) })
                        }
                    }
                    entries.append(.item("Remove This Post", enabled: board.posts.count > 1) {
                        if let front = store.front(of: board) { store.removePost(front, from: board.id) }
                    })
                    entries.append(.item("Unstack", detail: "Each post an artboard") { store.spreadOut(board.id) })
                }
            }
            let export: LocalizedStringResource =
                if nodes.count > 1 { "Export \(nodes.count) Layers…" }
                else if nodes.first?.isDeck == true { "Export Post…" }
                else if nodes.first?.isArtboard == true { "Export Artboard…" }
                else if nodes.first?.isRepeatGrid == true { "Export Grid…" }
                else if nodes.first?.isGroup == true { "Export Group…" }
                else { "Export Layer…" }
            entries += [.separator, .item(export, shortcut: "⌘E") { ExportPanel.present(for: store) }]
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
