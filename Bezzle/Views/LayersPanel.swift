import SwiftUI
import AppKit

/// Every layer, topmost first: artboards with what lies on them, and loose layers on the canvas.
/// A click selects, a double click renames, a drag moves a layer up or down, or onto a group or
/// an artboard's name to put it in there, open or shut.
/// While something on one artboard is selected, the list is a page of that artboard's layers
/// alone, with the way back to every layer at the top. The artboard itself is picked among the rest.
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
    @State private var dropSpot: DropSpot?
    @State private var anchor: UUID?
    /// The artboard whose layers the list shows on their own; nil for every layer.
    @State private var page: UUID?
    @State private var turning = Turn()
    /// When the list last turned to another page, so that the second click of a double click
    /// does not rename whichever row came to be under the pointer.
    @State private var turnedAt: TimeInterval = 0
    /// How far down each page is, apart, so the page sliding away stays where it was.
    @State private var scrolls: [UUID?: ScrollPosition] = [:]
    @State private var sight = Sight()

    static let rowHeight: CGFloat = 28
    private static let headerHeight: CGFloat = 20
    /// How far the list dissolves at an edge with more beyond it.
    private static let fade: CGFloat = 16
    private static let bottomPadding: CGFloat = 16

    /// The part of the list in sight. Kept out of view state, as it changes with every step of a scroll.
    private final class Sight {
        var rect: CGRect = .zero
    }

    /// Which way the list last turned: 1 into an artboard's page, -1 back out, 0 from one page to
    /// another. Read as the pages slide, so the one going knows where to go.
    final class Turn {
        var way: CGFloat = 0
    }

    /// Where a dragged layer goes when let go: into the gap above a row, the rows' count for the
    /// end, or onto a row that holds layers, and so in on top of them.
    private enum DropSpot: Equatable {
        case gap(Int)
        case onto(Int)
    }

    struct Row: Identifiable {
        let node: Node
        let depth: Int
        let parent: UUID?
        var id: UUID { node.id }
    }

    /// What is selected, the artboard it lies on, and whether any of it lies on that artboard
    /// rather than being the artboard, so the list follows a layer moved onto another artboard
    /// as well as a new selection.
    private struct Picked: Equatable {
        let ids: [UUID]
        let board: UUID?
        let inside: Bool
    }

    private var picked: Picked {
        let ids = store.selection
        return Picked(ids: ids, board: artboard(for: ids), inside: ids.contains { store.node($0)?.isArtboard == false })
    }

    /// The artboard being shown on its own, while there is one.
    private var board: Node? {
        page.flatMap { store.node($0) }.flatMap { $0.isArtboard ? $0 : nil }
    }

    private func isShut(_ node: Node) -> Bool {
        node.isGroup ? !openGroups.contains(node.id) : collapsed.contains(node.id)
    }

    /// What a layer holds as the list shows it: a repeat grid only its first cell, which the others
    /// follow, and a deck only the post in front.
    private func listed(in node: Node) -> [Node] {
        if node.isDeck { return store.seenLayers(of: node) }
        guard node.isRepeatGrid, let layout = RepeatGrid.layout(of: node) else { return node.children }
        return [node.children[layout.first]]
    }

    private var rows: [Row] {
        var out: [Row] = []
        func add(_ nodes: [Node], depth: Int, parent: UUID?) {
            for node in nodes.reversed() {
                out.append(Row(node: node, depth: depth, parent: parent))
                if node.isContainer && !isShut(node) { add(listed(in: node), depth: depth + 1, parent: node.id) }
            }
        }
        if let board { add(listed(in: board), depth: 0, parent: board.id) } else { add(store.doc.nodes, depth: 0, parent: nil) }
        return out
    }

    var body: some View {
        let rows = rows
        let board = board
        VStack(alignment: .leading, spacing: 0) {
            // The title stays where it is as the artboard's name comes and goes beside it, and
            // nothing here may take a second line, so the list below never moves.
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                LayersTitle(back: board == nil ? nil : { showAll() })
                if let board {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.ink4)
                    BoardCrumb(board: board, store: store,
                               renaming: renaming == board.id,
                               draft: $draft,
                               rename: { startRenaming(board) },
                               finishRename: { keep in endRenaming(board.id, keep: keep) })
                }
                Spacer(minLength: 8)
                Text(verbatim: (board.map { BezzleDocument.layerCount(listed(in: $0)) } ?? store.layerCount).formatted())
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(height: Self.headerHeight)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)

            // The pages lie over each other as one slides away and the next comes in.
            ZStack(alignment: .topLeading) {
                list(rows)
                    .id(board?.id)
                    .transition(PageTurn(turn: turning))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .contentShape(Rectangle())
        .onAppear {
            // A design with many artboards starts with them shut, as a list of thousands helps no one.
            if store.doc.artboards.count > 12 { collapsed = Set(store.doc.artboards.map(\.id)) }
            page = target(for: picked)
            reveal()
        }
        .onChange(of: picked) { old, new in
            reveal()
            let turned = !new.ids.isEmpty && turn(to: target(for: new))
            bringIntoSight(turned ? new.ids : new.ids.filter { !old.ids.contains($0) }, animated: !turned)
            if let id = renaming, !store.selection.contains(id) { endRenaming(keep: true) }
        }
    }

    @ViewBuilder private func list(_ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(board == nil ? "Nothing here yet." : "Nothing on this artboard yet.")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                    Text(board == nil ? "Draw an artboard with A, or a shape with R, E or L." : "Draw a shape on it with R, E or L.")
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
                                     rename: { if !justTurned { startRenaming(row.node) } },
                                     finishRename: { keep in endRenaming(row.id, keep: keep) })
                            .gesture(drag(row, rows: rows))
                        }
                    }
                    .overlay(alignment: .topLeading) { dropMark(rows) }
                    .padding(.horizontal, 8)
                    .padding(.bottom, Self.bottomPadding)
                    .coordinateSpace(name: "layers")
                }
                .scrollPosition(scrolled(board?.id))
                .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { [sight] _, rect in sight.rect = rect }
                .scrollIndicators(.never)
                .edgeFade(length: Self.fade)
            }
        }
    }

    // MARK: Pages

    /// The artboard a selection lies on: nil when it lies on more than one, or off them.
    private func artboard(for selection: [UUID]) -> UUID? {
        let boards = Set(selection.map { store.node($0)?.isArtboard == true ? $0 : store.doc.artboard(of: $0)?.id })
        return boards.count == 1 ? boards.first ?? nil : nil
    }

    /// The page for a selection: its artboard's once something on the artboard is picked. The
    /// artboard alone keeps its page if that is open, and is otherwise shown among every layer.
    private func target(for picked: Picked) -> UUID? {
        picked.inside || picked.board == board?.id ? picked.board : nil
    }

    /// Shows this artboard's layers on their own, or every layer for nil. Whether it turned.
    private func turn(to target: UUID?) -> Bool {
        let current = board?.id
        guard target != current else {
            page = target
            return false
        }
        turning.way = current == nil ? 1 : target == nil ? -1 : 0
        turnedAt = ProcessInfo.processInfo.systemUptime
        // The new page starts at its top, however far down it was last time.
        scrolls[target] = ScrollPosition(edge: .top)
        sight.rect.origin = .zero
        withAnimation(Theme.unfold) { page = target }
        return true
    }

    /// Back to every layer, with the artboard that was open in sight.
    private func showAll() {
        guard let from = board?.id else { return }
        endRenaming(keep: true)
        _ = turn(to: nil)
        bringIntoSight([from], animated: false)
    }

    private var justTurned: Bool {
        ProcessInfo.processInfo.systemUptime - turnedAt < NSEvent.doubleClickInterval
    }

    private func startRenaming(_ node: Node) {
        endRenaming(keep: true)
        draft = node.name
        renaming = node.id
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

    /// Scrolls the list to the topmost of these layers, unless one of them is in sight already.
    /// One partly in sight is brought in just far enough; one out of sight comes to the middle.
    private func bringIntoSight(_ ids: [UUID], animated: Bool = true) {
        guard !ids.isEmpty else { return }
        let rows = rows
        let wanted = Set(ids)
        let tops = rows.indices.filter { wanted.contains(rows[$0].id) }.map { CGFloat($0) * Self.rowHeight }
        guard let top = tops.first else { return }
        let shown = sight.rect
        // A row under the fade at an edge is not quite in sight.
        let clear = shown.insetBy(dx: 0, dy: Self.fade)
        if tops.contains(where: { clear.minY <= $0 && $0 + Self.rowHeight <= clear.maxY }) { return }

        let bottom = top + Self.rowHeight
        let y: CGFloat
        if bottom > shown.minY && top < shown.maxY {
            y = top < clear.minY ? top - Self.fade : bottom + Self.fade - shown.height
        } else {
            y = top + Self.rowHeight / 2 - shown.height / 2
        }
        let farthest = CGFloat(rows.count) * Self.rowHeight + Self.bottomPadding - shown.height
        let target = min(max(y, 0), max(farthest, 0))
        let page = board?.id
        if animated {
            withAnimation(Theme.unfold) { scrolls[page, default: ScrollPosition(edge: .top)].scrollTo(y: target) }
        } else {
            scrolls[page, default: ScrollPosition(edge: .top)].scrollTo(y: target)
        }
    }

    private func scrolled(_ page: UUID?) -> Binding<ScrollPosition> {
        Binding(get: { scrolls[page] ?? ScrollPosition(edge: .top) }, set: { scrolls[page] = $0 })
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
        // Picking an artboard here, or going into one, shows it on the canvas as well.
        if let target = artboard(for: store.selection), target != board?.id { store.show(target) }
    }

    // MARK: Moving layers by dragging

    private func drag(_ row: Row, rows: [Row]) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("layers"))
            .onChanged { value in
                if dragging == nil { dragging = row.id }
                dropSpot = spot(at: value.location.y, for: row, rows: rows)
            }
            .onEnded { _ in
                if let spot = dropSpot { drop(row, at: spot, rows: rows) }
                dragging = nil
                dropSpot = nil
            }
    }

    /// The middle half of a row that can take the layer is onto it; anywhere else is the gap nearest.
    private func spot(at y: CGFloat, for row: Row, rows: [Row]) -> DropSpot {
        let at = y / Self.rowHeight
        let i = Int(at.rounded(.down))
        if rows.indices.contains(i), abs(at - CGFloat(i) - 0.5) < 0.25, canHold(rows[i], row) { return .onto(i) }
        return .gap(min(max(Int(at.rounded()), 0), rows.count))
    }

    /// Whether `id` is the dragged layer or lies in it: nothing goes into itself, or into what it holds.
    private func within(_ id: UUID, _ row: Row) -> Bool {
        id == row.id || store.doc.ancestors(of: id).contains { $0.id == row.id }
    }

    /// Whether the layer a row shows can take the dragged one: an artboard or a group, though no
    /// repeat grid, as its cells follow its first. Artboards themselves go into nothing.
    private func canHold(_ target: Row, _ row: Row) -> Bool {
        !row.node.isArtboard && target.node.isContainer && !target.node.isRepeatGrid && !within(target.id, row)
    }

    /// Where a dropped layer goes: on top of what is in the row it was let go onto, or between
    /// the rows above and below the gap it was let go over.
    private func destination(for row: Row, spot: DropSpot, rows: [Row]) -> (parent: UUID?, index: Int, depth: Int)? {
        let slot: Int
        switch spot {
        case .onto(let i):
            guard rows.indices.contains(i), canHold(rows[i], row) else { return nil }
            return (rows[i].id, rows[i].node.children.count, rows[i].depth + 1)
        case .gap(let i):
            slot = i
        }
        var above = slot > 0 ? rows[slot - 1] : nil
        // Artboards only go between the layers on the canvas itself.
        if row.node.isArtboard {
            while let a = above, a.depth > 0 { above = rows.first { $0.id == a.parent } }
        }
        guard let above else { return board.map { ($0.id, $0.children.count, 0) } ?? (nil, store.doc.nodes.count, 0) }
        if above.id == row.id { return nil }
        if !row.node.isArtboard && above.node.isContainer && !isShut(above.node) {
            // Just under an open artboard's or group's name: on top of what is in it.
            return within(above.id, row) || above.node.isRepeatGrid ? nil : (above.id, above.node.children.count, above.depth + 1)
        }
        if let parent = above.parent, let container = store.node(parent),
           let i = container.children.firstIndex(where: { $0.id == above.id }) {
            return row.node.isArtboard || within(parent, row) || container.isRepeatGrid ? nil : (parent, i, above.depth)
        }
        guard let i = store.doc.nodes.firstIndex(where: { $0.id == above.id }) else { return nil }
        return (nil, i, 0)
    }

    private func drop(_ row: Row, at spot: DropSpot, rows: [Row]) {
        guard let (parent, index, _) = destination(for: row, spot: spot, rows: rows) else { return }
        if !store.selection.contains(row.id) { store.selection = [row.id] }
        store.move(row.id, to: parent, at: index)
        // A group or artboard let go onto opens if shut, to show the layer where it went.
        if case .onto = spot { withAnimation(Theme.unfold) { reveal() } }
    }

    /// A line in the gap the layer would go into, or a ring around the row it would go into.
    @ViewBuilder private func dropMark(_ rows: [Row]) -> some View {
        if let spot = dropSpot, let id = dragging, let row = rows.first(where: { $0.id == id }),
           let (_, _, depth) = destination(for: row, spot: spot, rows: rows) {
            switch spot {
            case .gap(let slot):
                Capsule()
                    .fill(Theme.pencil)
                    .frame(height: 2)
                    .padding(.leading, 10 + CGFloat(depth) * 18)
                    .offset(y: CGFloat(slot) * Self.rowHeight - 1)
                    .allowsHitTesting(false)
            case .onto(let i):
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.pencil, lineWidth: 2)
                    .frame(height: Self.rowHeight)
                    .offset(y: CGFloat(i) * Self.rowHeight)
                    .allowsHitTesting(false)
            }
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

/// How the list turns a page: the page coming in slides from the side it lies on, an artboard's
/// to the right of every layer, as the one going slides away to the other. Between two artboards
/// they only fade.
private struct PageTurn: Transition {
    let turn: LayersPanel.Turn

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .offset(x: -CGFloat(phase.value) * turn.way * 36)
            .opacity(phase.isIdentity ? 1 : 0)
    }
}

/// The panel's title, which on an artboard's page is the way back to every layer.
private struct LayersTitle: View {
    let back: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        Text("Layers")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(back == nil || hovering ? Theme.ink : Theme.ink3)
            .lineLimit(1)
            .fixedSize()
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { back?() }
            .help(back == nil ? "" : "Show every artboard")
            .animation(Theme.quick, value: hovering)
    }
}

/// The name of the artboard whose page is open: a click selects the artboard, a double click renames it.
private struct BoardCrumb: View {
    let board: Node
    let store: DocumentStore
    let renaming: Bool
    @Binding var draft: String
    let rename: () -> Void
    /// Whether to keep what was typed.
    let finishRename: (Bool) -> Void
    @State private var hovering = false
    @State private var lastClick: TimeInterval = 0
    @FocusState private var focused: Bool

    var body: some View {
        let selected = store.selection.contains(board.id)
        Group {
            if renaming {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onAppear { focused = true }
                    .onSubmit { finishRename(true) }
                    .onExitCommand { finishRename(false) }
                    .onChange(of: focused) { _, now in if !now { finishRename(true) } }
            } else {
                Text(board.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Theme.ink)
        // Its highlight reaches past the name, which stays in line with the crumbs beside it.
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Theme.pencilWash : hovering || store.hovered == board.id ? Theme.ink.opacity(0.05) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            store.hovered = inside ? board.id : (store.hovered == board.id ? nil : store.hovered)
        }
        .onTapGesture {
            let now = ProcessInfo.processInfo.systemUptime
            let second = (NSApp.currentEvent?.clickCount ?? 1) >= 2 || now - lastClick < NSEvent.doubleClickInterval
            lastClick = second ? 0 : now
            if second {
                rename()
            } else {
                store.canvas?.endEditing()
                store.selection = [board.id]
                store.show(board.id)
            }
        }
        .padding(.horizontal, -4)
        .padding(.vertical, -2)
        .animation(Theme.quick, value: hovering)
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

            Group {
                if node.isRepeatGrid { RepeatGridGlyph() } else { KindGlyph(kind: node.kind) }
            }
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
            if let spec = node.grid, !hovering {
                Text(verbatim: "\(spec.columns)×\(spec.rows)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.ink3)
            }
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
    let help: LocalizedStringResource
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
            .help(Text(help))
    }
}
