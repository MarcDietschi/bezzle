import SwiftUI
import AppKit

/// Every layer, topmost first: artboards with what lies on them, and loose layers on the canvas.
/// A click selects, a double click renames, a drag moves a layer up or down or onto another artboard.
struct LayersPanel: View {
    let store: DocumentStore
    /// Artboards are open until shut; groups are shut until opened, as there can be thousands.
    @State private var collapsed: Set<UUID> = []
    @State private var openGroups: Set<UUID> = []
    @State private var renaming: UUID?
    /// What is typed into the name being changed, kept here so that choosing another layer, here
    /// or on the canvas, can finish the renaming with it.
    @State private var draft = ""
    @State private var dragging: UUID?
    @State private var dropSlot: Int?
    @State private var anchor: UUID?

    static let rowHeight: CGFloat = 28

    struct Row: Identifiable {
        let node: Node
        let depth: Int
        let parent: UUID?
        var id: UUID { node.id }
    }

    private func isShut(_ node: Node) -> Bool {
        node.isGroup ? !openGroups.contains(node.id) : collapsed.contains(node.id)
    }

    private var rows: [Row] {
        var out: [Row] = []
        func add(_ nodes: [Node], depth: Int, parent: UUID?) {
            for node in nodes.reversed() {
                out.append(Row(node: node, depth: depth, parent: parent))
                if node.isContainer && !isShut(node) { add(node.children, depth: depth + 1, parent: node.id) }
            }
        }
        add(store.doc.nodes, depth: 0, parent: nil)
        return out
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Layers")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("\(store.layerCount)")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing here yet.")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                    Text("Draw an artboard with A, or a shape with R, E or L.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                Spacer()
            } else {
                ScrollView {
                    // Only the rows in sight are made: a large design has thousands.
                    LazyVStack(spacing: 0) {
                        LayerBranches(rows: rows[...]) { row in
                            LayerRow(row: row, store: store,
                                     collapsed: isShut(row.node),
                                     renaming: renaming == row.id,
                                     draft: $draft,
                                     dimmed: dragging == row.id,
                                     toggle: { toggle(row.node) },
                                     select: { select(row, rows: rows) },
                                     rename: { startRenaming(row) },
                                     finishRename: { keep in endRenaming(row.id, keep: keep) })
                            .gesture(drag(row, rows: rows))
                        }
                    }
                    .overlay(alignment: .topLeading) { dropLine(rows) }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 16)
                    .coordinateSpace(name: "layers")
                }
                .scrollIndicators(.never)
                .edgeFade(length: 16)
            }
        }
        .contentShape(Rectangle())
        .onAppear {
            // A design with many artboards starts with them shut, as a list of thousands helps no one.
            if store.doc.artboards.count > 12 { collapsed = Set(store.doc.artboards.map(\.id)) }
            reveal()
        }
        .onChange(of: store.selection) {
            reveal()
            if let id = renaming, !store.selection.contains(id) { endRenaming(keep: true) }
        }
    }

    private func startRenaming(_ row: Row) {
        endRenaming(keep: true)
        draft = row.node.name
        renaming = row.id
    }

    /// Ends the renaming of `id`, or of whichever layer is being renamed, keeping what was typed or not.
    private func endRenaming(_ id: UUID? = nil, keep: Bool) {
        guard let current = renaming, id == nil || id == current else { return }
        if keep { store.renameLayer(current, to: draft) }
        renaming = nil
    }

    /// Opens the artboards and groups a selected layer is in, so it shows in the list.
    private func reveal() {
        for id in store.selection {
            for holder in store.doc.ancestors(of: id) {
                if holder.isGroup { openGroups.insert(holder.id) } else { collapsed.remove(holder.id) }
            }
        }
    }

    private func toggle(_ node: Node) {
        withAnimation(Theme.unfold) {
            if node.isGroup {
                if openGroups.contains(node.id) { openGroups.remove(node.id) } else { openGroups.insert(node.id) }
            } else if collapsed.contains(node.id) {
                collapsed.remove(node.id)
            } else {
                collapsed.insert(node.id)
            }
        }
    }

    /// Plain click: just this one. Shift: everything between it and the last one clicked. Command: add or remove it.
    private func select(_ row: Row, rows: [Row]) {
        store.canvas?.endEditing()
        if renaming != row.id { endRenaming(keep: true) }
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if store.selection.contains(row.id) { store.selection.removeAll { $0 == row.id } } else { store.selection.append(row.id) }
            anchor = row.id
        } else if flags.contains(.shift), let anchor, let a = rows.firstIndex(where: { $0.id == anchor }),
                  let b = rows.firstIndex(where: { $0.id == row.id }) {
            let range = min(a, b)...max(a, b)
            store.selection = rows[range].filter { $0.parent == row.parent }.map(\.id)
        } else {
            store.selection = [row.id]
            anchor = row.id
        }
    }

    // MARK: Moving layers by dragging

    private func drag(_ row: Row, rows: [Row]) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("layers"))
            .onChanged { value in
                if dragging == nil { dragging = row.id }
                let slot = Int((value.location.y / Self.rowHeight).rounded())
                dropSlot = min(max(slot, 0), rows.count)
            }
            .onEnded { _ in
                if let slot = dropSlot { drop(row, at: slot, rows: rows) }
                dragging = nil
                dropSlot = nil
            }
    }

    /// Where a dropped layer goes: between the rows above and below the gap it was let go over.
    private func destination(for row: Row, slot: Int, rows: [Row]) -> (parent: UUID?, index: Int, depth: Int)? {
        var above = slot > 0 ? rows[slot - 1] : nil
        // Artboards only go between the layers on the canvas itself.
        if row.node.isArtboard {
            while let a = above, a.depth > 0 { above = rows.first { $0.id == a.parent } }
        }
        guard let above else { return (nil, store.doc.nodes.count, 0) }
        if above.id == row.id { return nil }
        // Nothing goes into itself, or into what it holds.
        func within(_ id: UUID) -> Bool { id == row.id || store.doc.ancestors(of: id).contains { $0.id == row.id } }
        if !row.node.isArtboard && above.node.isContainer && !isShut(above.node) {
            // Just under an open artboard's or group's name: on top of what is in it.
            return within(above.id) ? nil : (above.id, above.node.children.count, above.depth + 1)
        }
        if above.depth > 0, let parent = above.parent, let container = store.node(parent),
           let i = container.children.firstIndex(where: { $0.id == above.id }) {
            return row.node.isArtboard || within(parent) ? nil : (parent, i, above.depth)
        }
        guard let i = store.doc.nodes.firstIndex(where: { $0.id == above.id }) else { return nil }
        return (nil, i, 0)
    }

    private func drop(_ row: Row, at slot: Int, rows: [Row]) {
        guard let (parent, index, _) = destination(for: row, slot: slot, rows: rows) else { return }
        if !store.selection.contains(row.id) { store.selection = [row.id] }
        store.move(row.id, to: parent, at: index)
    }

    @ViewBuilder private func dropLine(_ rows: [Row]) -> some View {
        if let slot = dropSlot, let id = dragging, let row = rows.first(where: { $0.id == id }),
           let (_, _, depth) = destination(for: row, slot: slot, rows: rows) {
            Capsule()
                .fill(Theme.pencil)
                .frame(height: 2)
                .padding(.leading, 10 + CGFloat(depth) * 18)
                .offset(y: CGFloat(slot) * Self.rowHeight - 1)
                .allowsHitTesting(false)
        }
    }
}

/// The rows in order, each followed by the rows nested under it. Those go in a block of their
/// own, so when a layer with layers in it shuts they fold away together, up under its row.
private struct LayerBranches<RowView: View>: View {
    struct Branch: Identifiable {
        let head: LayersPanel.Row
        let under: ArraySlice<LayersPanel.Row>
        var id: UUID { head.id }
    }

    let rows: ArraySlice<LayersPanel.Row>
    let row: (LayersPanel.Row) -> RowView

    var body: some View {
        ForEach(branches) { branch in
            row(branch.head)
            if !branch.under.isEmpty {
                LazyVStack(spacing: 0) {
                    LayerBranches(rows: branch.under, row: row)
                }
                .transition(.unfold)
            }
        }
    }

    /// Each row at the shallowest depth here, with the deeper rows that follow it.
    private var branches: [Branch] {
        guard let depth = rows.first?.depth else { return [] }
        var out: [Branch] = []
        var i = rows.startIndex
        while i < rows.endIndex {
            var end = rows.index(after: i)
            while end < rows.endIndex && rows[end].depth > depth { end += 1 }
            out.append(Branch(head: rows[i], under: rows[rows.index(after: i)..<end]))
            i = end
        }
        return out
    }
}

private struct LayerRow: View {
    let row: LayersPanel.Row
    let store: DocumentStore
    let collapsed: Bool
    let renaming: Bool
    @Binding var draft: String
    let dimmed: Bool
    let toggle: () -> Void
    let select: () -> Void
    let rename: () -> Void
    /// Whether to keep what was typed.
    let finishRename: (Bool) -> Void
    @State private var hovering = false
    /// When this row was last clicked once, to tell a double click.
    @State private var lastClick: TimeInterval = 0
    @FocusState private var focused: Bool

    var body: some View {
        let node = row.node
        let selected = store.selection.contains(node.id)
        HStack(spacing: 6) {
            Group {
                if node.isContainer {
                    Chevron(color: Theme.ink3)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: toggle)
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
            }
            .padding(.leading, CGFloat(row.depth) * 18)

            KindGlyph(kind: node.kind)
                .foregroundStyle(selected ? Theme.ink : Theme.ink3)

            if renaming {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($focused)
                    .onAppear { focused = true }
                    .onSubmit { finishRename(true) }
                    .onExitCommand { finishRename(false) }
                    .onChange(of: focused) { _, now in if !now { finishRename(true) } }
            } else {
                Text(node.name)
                    .font(.system(size: 12.5, weight: node.isArtboard || selected ? .medium : .regular))
                    .foregroundStyle(node.hidden ? Theme.ink3 : Theme.ink)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering || node.locked {
                RowIcon(symbol: node.locked ? "lock.fill" : "lock.open", on: node.locked, help: node.locked ? "Unlock" : "Lock") {
                    store.setLocked(!node.locked, [node.id])
                }
            }
            if hovering || node.hidden {
                RowIcon(symbol: node.hidden ? "eye.slash" : "eye", on: node.hidden, help: node.hidden ? "Show" : "Hide") {
                    store.setHidden(!node.hidden, [node.id])
                }
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .frame(height: LayersPanel.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Theme.pencilWash : hovering || store.hovered == node.id ? Theme.ink.opacity(0.05) : .clear)
        }
        .opacity(dimmed ? 0.4 : 1)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            store.hovered = inside ? node.id : (store.hovered == node.id ? nil : store.hovered)
        }
        // One gesture that counts the clicks itself: a double-click gesture beside a single one
        // holds every single click back until a second one can no longer come.
        .onTapGesture {
            let now = ProcessInfo.processInfo.systemUptime
            let second = (NSApp.currentEvent?.clickCount ?? 1) >= 2 || now - lastClick < NSEvent.doubleClickInterval
            lastClick = second ? 0 : now
            if second { rename() } else { select() }
        }
        .animation(Theme.quick, value: hovering)
    }
}

private struct RowIcon: View {
    let symbol: String
    let on: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(hovering ? Theme.ink : on ? Theme.ink2 : Theme.ink3)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .help(help)
    }
}
