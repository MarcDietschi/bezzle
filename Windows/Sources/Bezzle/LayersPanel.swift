import Foundation
import WinUI
import UWP
import BezzleCore
import WinSDK

/// The layers list (the Mac's LayersPanel): "Layers", and on an artboard's page a chevron and
/// its name, the count at the right; rows 28 tall, 18 in a level, the kind's picture and the
/// name; the selected row on a wash of pencil, radius 7, the one under the pointer on ink at 5%.
/// A click selects (Ctrl adds or removes, Shift takes everything between it and the last one
/// clicked), a double click renames; lock and eye show at the right under the pointer, and stay
/// while a layer is locked or hidden.
@MainActor
final class LayersPanel {
    let root = Grid()
    private let session: DesignSession
    private let header = Grid()
    private let rows = StackPanel()
    /// Which rows are folded, as on the Mac: groups are shut until opened, artboards open until shut.
    private var openGroups: Set<UUID> = []
    private var collapsed: Set<UUID> = []
    private func isShut(_ id: UUID, isGroup: Bool) -> Bool { isGroup ? !openGroups.contains(id) : collapsed.contains(id) }
    private func toggle(_ id: UUID, isGroup: Bool) {
        if isGroup {
            if openGroups.contains(id) { openGroups.remove(id) } else { openGroups.insert(id) }
        } else {
            if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        }
    }
    /// The rows shown, by layer, to light the one the pointer is on elsewhere.
    private var shown: [UUID: Pressable] = [:]
    /// A row being dragged: where it was pressed (in the list), and where it would go.
    private var dragging: (id: UUID, from: Double, moved: Bool, place: WindowsCore.DropPlace?)?
    private let marks = Canvas()
    private let gapMark = Border()
    private let ringMark = Border()
    /// The rows as listed, top first, with what holds each: for Shift's range.
    private var listed: [(id: UUID, parent: UUID?)] = []
    /// The row last clicked on its own, where Shift's range starts, and when, to tell a double click.
    private var anchor: UUID?
    private var lastClick: (id: UUID, at: DWORD)?
    /// The layer being renamed, in a field in its row.
    private var renaming: UUID?

    init(session: DesignSession) {
        self.session = session
        root.width = Theme.layersWidth
        let top = RowDefinition()
        top.height = GridLength(value: 1, gridUnitType: .auto)
        let rest = RowDefinition()
        rest.height = GridLength(value: 1, gridUnitType: .star)
        root.rowDefinitions.append(top)
        root.rowDefinitions.append(rest)

        header.margin = Theme.inset(16, 8, 16, 6)
        header.height = 20
        root.children.append(header)

        rows.margin = Theme.inset(8, 0, 8, 16)
        // Over the rows, where a dragged one would go: a line of pencil in a gap, or a ring
        // round the row it would go into.
        gapMark.height = 2
        gapMark.cornerRadius = Theme.corners(1)
        gapMark.background = Theme.brush(Theme.pencil)
        ringMark.height = 28
        ringMark.cornerRadius = Theme.corners(7)
        ringMark.borderBrush = Theme.brush(Theme.pencil)
        ringMark.borderThickness = Theme.inset(2)
        for mark in [gapMark, ringMark] {
            mark.isHitTestVisible = false
            mark.visibility = .collapsed
            marks.children.append(mark)
        }
        marks.isHitTestVisible = false
        marks.margin = rows.margin
        let stack = Grid()
        stack.children.append(rows)
        stack.children.append(marks)
        let scroll = ScrollView()
        scroll.content = stack
        try? Grid.setRow(scroll, 1)
        root.children.append(scroll)

        session.listen { [weak self] in self?.show() }
        session.listenToHover { [weak self] in
            guard let self else { return }
            for (id, row) in self.shown { row.point(id == self.session.hovered) }
        }
        show()
    }

    /// The selection the list last showed, to open what a newly selected layer is in.
    private var revealed: [UUID] = []

    func show() {
        root.visibility = session.showsLayers ? .visible : .collapsed
        // The artboards and groups a newly selected layer is in open, so it shows in the list (the
        // Mac's reveal); one shut by hand while it stays selected stays shut.
        if session.selection != revealed {
            revealed = session.selection
            for id in session.selection {
                for holder in WindowsCore.holders(of: id) {
                    if holder.isGroup { openGroups.insert(holder.id) } else { collapsed.remove(holder.id) }
                }
            }
        }
        let boards = WindowsCore.boards()
        let board = session.board.flatMap { b in boards.first { $0.index == b } }
        header.children.clear()
        let title = StackPanel()
        title.orientation = .horizontal
        title.spacing = 6
        title.children.append(Theme.text("Layers", size: 13, weight: 600))
        if let board {
            title.children.append(Glyphs.view(Glyphs.chevron(open: false, size: 9.5), size: 9.5, brush: Theme.ink(4)))
            title.children.append(Theme.text(board.name, size: 13, weight: 600))
        }
        header.children.append(title)

        rows.children.clear()
        listed = []
        shown = [:]
        if let board {
            let layers = WindowsCore.layers(board: board.index)
            let byID = Dictionary(layers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let count = Theme.text("\(layers.filter { $0.depth == 0 }.count)", size: 11.5, ink: 3)
            count.horizontalAlignment = .right
            header.children.append(count)
            // Front first, as the Mac lists them (the shared `Node.listed`).
            for r in WindowsCore.rows(board: board.index, isShut: { [unowned self] id, group in self.isShut(id, isGroup: group) }) {
                guard let layer = byID[r.id] else { continue }
                listed.append((r.id, r.parent))
                rows.children.append(row(layer, depth: r.depth, board: board.index))
            }
        } else {
            // The canvas: its artboards and the layers lying on it, front first.
            let loose = WindowsCore.looseLayers().map(\.index)
            let count = Theme.text("\(boards.count + loose.count)", size: 11.5, ink: 3)
            count.horizontalAlignment = .right
            header.children.append(count)
            for index in (boards.map(\.index) + loose).sorted(by: >) {
                if let b = boards.first(where: { $0.index == index }) {
                    rows.children.append(boardRow(b))
                    continue
                }
                let layers = WindowsCore.layers(board: index)
                let byID = Dictionary(layers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for r in WindowsCore.rows(board: index, isShut: { [unowned self] id, group in self.isShut(id, isGroup: group) }) {
                    guard let layer = byID[r.id] else { continue }
                    listed.append((r.id, r.parent))
                    rows.children.append(row(layer, depth: r.depth, board: index))
                }
            }
        }
    }

    private func row(_ layer: WindowsCore.Layer, depth: Int, board: Int) -> UIElement {
        let selected = session.selection.contains(layer.id)
        let button = Pressable(radius: 7) { [weak self] in self?.clicked(layer.id, board: board) }
        button.onLook = { Theme.brush(Theme.pencil, Theme.pencilWash) }
        button.box.height = 28
        let grid = Grid()
        for width in [GridLength(value: 1, gridUnitType: .star), GridLength(value: 1, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = width
            grid.columnDefinitions.append(column)
        }
        let line = StackPanel()
        line.orientation = .horizontal
        line.spacing = 6
        line.margin = Theme.inset(4 + Double(depth) * 18, 0, 4, 0)
        line.verticalAlignment = .center
        // The chevron's room, kept for rows that hold nothing too, so names line up.
        let chevron = Border()
        chevron.width = 14
        chevron.height = 14
        if layer.isContainer {
            chevron.child = Glyphs.view(Glyphs.chevron(open: !isShut(layer.id, isGroup: layer.kind == "group")), size: 9, brush: Theme.ink(3))
            chevron.padding = Theme.inset(2.5)
            chevron.background = Theme.clear
            chevron.pointerPressed.addHandler { _, args in args?.handled = true }
            chevron.pointerReleased.addHandler { [weak self] _, args in
                args?.handled = true
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard let self else { return }
                    self.toggle(layer.id, isGroup: layer.kind == "group")
                    self.show()
                } }
            }
        }
        line.children.append(chevron)
        let glyph = layer.isCopy ? Theme.brush(Theme.linked) : Theme.ink(selected ? 1 : 3)
        line.children.append(Glyphs.view(Glyphs.kind(layer.kind), size: 15, brush: glyph))
        let room = Theme.layersWidth - 16 - 86 - Double(depth) * 18
        if renaming == layer.id {
            line.children.append(renameField(layer, width: room))
        } else {
            let name = Theme.text(layer.name, size: 12.5, weight: selected ? 500 : 400, ink: layer.hidden ? 3 : 1)
            name.maxWidth = room
            name.textTrimming = .characterEllipsis
            line.children.append(name)
        }
        grid.children.append(line)

        // Lock and eye, under the pointer, or while locked or hidden.
        let icons = StackPanel()
        icons.orientation = .horizontal
        icons.margin = Theme.inset(0, 0, 4, 0)
        icons.verticalAlignment = .center
        let lock = icon(Glyphs.lock(locked: layer.locked), on: layer.locked) { [weak self] in
            WindowsCore.setLocked([layer.id], !layer.locked)
            self?.session.edited(board: board)
        }
        let eye = icon(Glyphs.eye(hidden: layer.hidden), on: layer.hidden) { [weak self] in
            WindowsCore.setHidden([layer.id], !layer.hidden)
            if !layer.hidden, let self, self.session.selection.contains(layer.id) {
                self.session.select(self.session.selection.filter { $0 != layer.id }, on: board)
            }
            self?.session.edited(board: board)
        }
        lock.visibility = layer.locked ? .visible : .collapsed
        eye.visibility = layer.hidden ? .visible : .collapsed
        icons.children.append(lock)
        icons.children.append(eye)
        try? Grid.setColumn(icons, 1)
        grid.children.append(icons)
        button.box.pointerEntered.addHandler { [weak self] _, _ in
            lock.visibility = .visible
            eye.visibility = .visible
            if self?.dragging == nil { self?.session.hovered = layer.id }
        }
        button.box.pointerExited.addHandler { [weak self] _, _ in
            lock.visibility = layer.locked ? .visible : .collapsed
            eye.visibility = layer.hidden ? .visible : .collapsed
            if self?.session.hovered == layer.id { self?.session.hovered = nil }
        }
        // A drag of 4 points moves the layer up or down the list, or into a group or artboard.
        button.box.pointerPressed.addHandler { [weak self] sender, args in
            // On the canvas's page, among its artboards, a layer is not moved by dragging its row yet.
            guard let self, !WindowsCore.isLoose(board), let p = try? args?.getCurrentPoint(self.rows)?.position else { return }
            self.dragging = (layer.id, Double(p.y), false, nil)
            _ = try? (sender as? UIElement)?.capturePointer(args?.pointer)
        }
        button.box.pointerMoved.addHandler { [weak self] _, args in
            guard let self, let d = self.dragging, d.id == layer.id, let p = try? args?.getCurrentPoint(self.rows)?.position else { return }
            guard d.moved || abs(Double(p.y) - d.from) >= 4 else { return }
            self.dragging?.moved = true
            let found = WindowsCore.dropPlace(layer.id, at: Double(p.y), board: board, isShut: { [unowned self] id, group in self.isShut(id, isGroup: group) })
            self.dragging?.place = found?.place
            self.showMark(found)
        }
        button.box.pointerReleased.addHandler { [weak self] sender, args in
            guard let self, let d = self.dragging, d.id == layer.id else { return }
            self.dragging = nil
            try? (sender as? UIElement)?.releasePointerCapture(args?.pointer)
            self.showMark(nil)
            guard d.moved, let place = d.place else { return }
            args?.handled = true
            DispatchQueue.main.async { MainActor.assumeIsolated {
                if !self.session.selection.contains(layer.id) { self.session.select([layer.id], on: board) }
                WindowsCore.drop(layer.id, at: place, board: board, isShut: { [unowned self] id, group in self.isShut(id, isGroup: group) })
                // A group let go onto opens, to show the layer where it went.
                if case .onto(let i) = place, i < self.listed.count, WindowsCore.isGroup(self.listed[i].id) { self.openGroups.insert(self.listed[i].id) }
                self.session.edited(board: board)
            } }
        }
        button.box.child = grid
        button.isOn = selected
        button.point(session.hovered == layer.id)
        shown[layer.id] = button
        return button.box
    }

    /// Where a dragged row would go: a line of pencil in the gap, as deep as it would be listed,
    /// or a ring round the row it would go into.
    private func showMark(_ found: (place: WindowsCore.DropPlace, depth: Int)?) {
        gapMark.visibility = .collapsed
        ringMark.visibility = .collapsed
        guard let found else { return }
        let width = Theme.layersWidth - 16
        switch found.place {
        case .gap(let slot):
            let indent = 10 + Double(found.depth) * 18
            gapMark.width = width - indent
            try? Canvas.setLeft(gapMark, indent)
            try? Canvas.setTop(gapMark, Double(slot) * 28 - 1)
            gapMark.visibility = .visible
        case .onto(let i):
            ringMark.width = width
            try? Canvas.setLeft(ringMark, 0)
            try? Canvas.setTop(ringMark, Double(i) * 28)
            ringMark.visibility = .visible
        }
    }

    /// A row's icon, 20 square: ink at 44%, 64% while on, full under the pointer.
    private func icon(_ glyph: [Glyphs.Part], on: Bool, _ action: @escaping @MainActor () -> Void) -> Border {
        let box = Border()
        box.width = 20
        box.height = 20
        box.background = Theme.clear
        let rest = on ? Theme.ink(2) : Theme.ink(3)
        let view = Glyphs.view(glyph, size: 12, brush: rest)
        view.horizontalAlignment = .center
        view.verticalAlignment = .center
        box.child = view
        box.pointerEntered.addHandler { sender, _ in
            ((sender as? Border)?.child as? FrameworkElement).map { Glyphs.paint($0, Theme.ink(1)) }
        }
        box.pointerExited.addHandler { sender, _ in
            ((sender as? Border)?.child as? FrameworkElement).map { Glyphs.paint($0, rest) }
        }
        box.pointerPressed.addHandler { _, args in args?.handled = true }
        box.pointerReleased.addHandler { _, args in
            args?.handled = true
            DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
        }
        return box
    }

    /// Plain click: just this one. Shift: everything between it and the last one clicked, among
    /// those lying with it. Ctrl (the Mac's Command): add or remove it. A second click on the
    /// same row soon after renames it.
    private func clicked(_ id: UUID, board: Int) {
        let now = Pressable.tap.at
        if let last = lastClick, last.id == id, now &- last.at <= GetDoubleClickTime() {
            lastClick = nil
            renaming = id
            show()
            return
        }
        lastClick = (id, now)
        if renaming != nil, renaming != id { renaming = nil }
        let control = Pressable.tap.control, shift = Pressable.tap.shift
        var picked = session.selection
        if control {
            if let i = picked.firstIndex(of: id) { picked.remove(at: i) } else { picked.append(id) }
            anchor = id
        } else if shift, let anchor, let a = listed.firstIndex(where: { $0.id == anchor }), let b = listed.firstIndex(where: { $0.id == id }) {
            let parent = listed[b].parent
            picked = listed[min(a, b)...max(a, b)].filter { $0.parent == parent }.map(\.id)
        } else {
            picked = [id]
            anchor = id
        }
        session.select(picked, on: board)
    }

    /// The name in a field to type over: Enter keeps it, Esc puts it back, leaving keeps it.
    private func renameField(_ layer: WindowsCore.Layer, width: Double) -> UIElement {
        let field = TextBox()
        field.text = layer.name
        field.fontFamily = Theme.ui
        field.fontSize = 12.5
        field.minWidth = 0
        field.minHeight = 0
        field.width = width
        field.padding = Theme.inset(2, 2, 2, 2)
        field.borderThickness = Theme.inset(0)
        field.background = Theme.brush(Theme.card)
        for key in ["TextControlBackgroundFocused", "TextControlBackgroundPointerOver", "TextControlBorderBrushFocused", "TextControlBorderBrushPointerOver"] {
            _ = field.resources?.insert(key, key.contains("Background") ? Theme.brush(Theme.card) : Theme.clear)
        }
        var done = false
        func finish(_ keep: Bool) {
            guard !done else { return }
            done = true
            renaming = nil
            if keep, field.text != layer.name {
                WindowsCore.rename(layer.id, to: field.text)
                session.edited(board: session.board)
            } else {
                show()
            }
        }
        field.previewKeyDown.addHandler { _, args in
            guard let args else { return }
            if args.key == .enter { args.handled = true; finish(true) }
            if args.key == .escape { args.handled = true; finish(false) }
        }
        field.lostFocus.addHandler { _, _ in finish(true) }
        field.loaded.addHandler { sender, _ in
            guard let field = sender as? TextBox else { return }
            _ = try? field.focus(.programmatic)
            try? field.selectAll()
        }
        return field
    }

    private func boardRow(_ board: WindowsCore.Board) -> UIElement {
        let selected = session.board == board.index && session.selection.isEmpty
        let button = Pressable(radius: 7) { [weak self] in self?.session.select([], on: board.index) }
        button.onLook = { Theme.brush(Theme.pencil, Theme.pencilWash) }
        button.box.height = 28
        let line = StackPanel()
        line.orientation = .horizontal
        line.spacing = 6
        line.margin = Theme.inset(4, 0, 6, 0)
        line.verticalAlignment = .center
        let room = Border()
        room.width = 14
        line.children.append(room)
        line.children.append(Glyphs.view(Glyphs.kind("artboard"), size: 15, brush: Theme.ink(3)))
        line.children.append(Theme.text(board.name, size: 12.5, weight: 500))
        button.box.child = line
        button.isOn = selected
        return button.box
    }
}
