import Foundation
import WinUI
import UWP
import BezzleCore
import WinSDK

/// A design's window, laid out as the Mac's (Views/Workspace.swift): the bar, then the tool rail,
/// the layers, the canvas (radius 12, 9 above the bottom and 2 in from the right) and the
/// inspector, on the paper.
@MainActor
final class DesignWindow {
    let root = Grid()
    let session: DesignSession
    let bar: Bar
    let rail: ToolRail
    let layers: LayersPanel
    let canvas: DesignCanvas
    let inspector: Inspector
    let menus = MenuHost()
    private lazy var export = ExportSheet(session: session)
    /// The prototype being played, over the panels and the canvas.
    private var playing: PlayerView?
    /// The ruler of time, at the foot of the canvas while it is out.
    private lazy var ruler = TimeRulerView(session: session)
    /// Ready-made parts and icons, in the layers list's place while it is out.
    private lazy var resources = ResourcesPanel(session: session)

    init(name: String, onClose: @escaping () -> Void) {
        session = DesignSession(name: name)
        bar = Bar(session: session, onClose: onClose)
        rail = ToolRail(session: session)
        layers = LayersPanel(session: session)
        canvas = DesignCanvas(session: session)
        inspector = Inspector(session: session)
        inspector.returnFocus = { [weak canvas] in canvas?.takeKeys() }

        root.background = Theme.brush(Theme.paper)
        let barRow = RowDefinition()
        barRow.height = GridLength(value: Theme.barHeight, gridUnitType: .pixel)
        let bodyRow = RowDefinition()
        bodyRow.height = GridLength(value: 1, gridUnitType: .star)
        root.rowDefinitions.append(barRow)
        root.rowDefinitions.append(bodyRow)
        root.children.append(bar.root)

        let body = Grid()
        for width in [GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .auto),
                      GridLength(value: 1, gridUnitType: .star), GridLength(value: 1, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = width
            body.columnDefinitions.append(column)
        }
        body.children.append(rail.root)
        try? Grid.setColumn(layers.root, 1)
        body.children.append(layers.root)
        try? Grid.setColumn(resources.root, 1)
        body.children.append(resources.root)
        resources.carry = { [weak self] thing, args in self?.canvas.carryResource(thing, args) }
        resources.drop = { [weak self] thing, args in self?.canvas.dropResource(thing, args) }
        resources.pick = { [weak self] thing in self?.canvas.pickResource(thing) }
        session.listenToEdits { [weak self] _ in self?.resources.edited() }

        // The canvas sits in the paper like a table top: radius 12, clipped, a hairline round it.
        let table = Border()
        table.cornerRadius = Theme.corners(12)
        table.borderBrush = Theme.brush(Theme.shadow, 0.14)
        table.borderThickness = Theme.inset(0.5)
        table.margin = Theme.inset(0, 0, 2, 9)
        table.child = canvas.root
        try? Grid.setColumn(table, 2)
        body.children.append(table)

        // The ruler of time, floating at the canvas's foot.
        try? Grid.setColumn(ruler.root, 2)
        body.children.append(ruler.root)
        WindowsCore.versions.changed = { [weak self] in
            guard let self else { return }
            self.ruler.refresh()
            self.canvas.versionsChanged()
            self.bar.versionsChanged()
        }
        WindowsCore.versions.edited = { [weak self] in self?.session.edited(board: nil) }
        bar.onVersions = { [weak self] in self?.toggleVersions() }

        // Why the design is not being saved, over the canvas's top, quietly.
        let notice = InfoBar()
        notice.severity = .warning
        notice.isClosable = true
        notice.title = "Not saved"
        notice.verticalAlignment = .top
        notice.margin = Theme.inset(28, 28, 28, 0)
        notice.maxWidth = 560
        try? Grid.setColumn(notice, 2)
        body.children.append(notice)
        session.onUnsaved = { why in
            notice.message = why ?? ""
            notice.isOpen = why != nil
        }

        try? Grid.setColumn(inspector.root, 3)
        body.children.append(inspector.root)
        try? Grid.setRow(body, 1)
        root.children.append(body)
        // The Export sheet over the window, and Bezzle's own menus over everything.
        try? Grid.setRowSpan(export.layer, 2)
        root.children.append(export.layer)
        bar.onExport = { [weak self] in self?.export.open() }
        bar.onPlay = { [weak self] in self?.play(from: nil) }
        session.openExport = { [weak self] in self?.export.open() }
        session.play = { [weak self] board in self?.play(from: board) }
        session.reveal = { [weak self] id in
            if let r = WindowsCore.canvasBounds(of: [id]) { self?.canvas.reveal(r) }
        }
        // Seen as layers again, the playing stops at once.
        session.listen { [weak self] in
            guard let self, self.session.mode != 1, let view = self.playing else { return }
            self.playing = nil
            view.player.stop()
            self.remove(view.layer)
        }
        try? Grid.setRowSpan(menus.layer, 2)
        root.children.append(menus.layer)
        canvas.menus = menus
        inspector.menus = menus
        bar.menus = menus
        bar.zoomEntries = { [weak self] in self?.zoomEntries() ?? [] }
        canvas.aidsMenu = { [weak self] in self?.aidsEntries() ?? [] }
        // The canvas's keys, wherever focus is, as on the Mac; but not while a field is typed into.
        root.keyDown.addHandler { [weak self] _, args in
            guard let self, let args, !args.handled else { return }
            // Alt held on a tone or colour of the Photo card shows only that part of the photo.
            if args.key == .menu { self.inspector.photoAltChanged() }
            if self.menus.isOpen {
                if args.key == .escape { args.handled = true; self.menus.close() }
                return
            }
            if let playing = self.playing {
                playing.key(args)
                return
            }
            // Ctrl+Enter plays the prototype, as ⌘↩ does on the Mac.
            if args.key == .enter, GetKeyState(Int32(VK_CONTROL)) < 0, self.session.mode == 1 {
                args.handled = true
                self.play(from: nil)
                return
            }
            if self.export.isOpen {
                if args.key == .escape { args.handled = true; self.export.close() }
                return
            }
            let focusedNow = try? FocusManager.getFocusedElement(self.root.xamlRoot)
            // Ctrl+Shift+Y brings the resources out or puts them away, as ⇧⌘Y does on the Mac.
            if args.key == .y, GetKeyState(Int32(VK_CONTROL)) < 0, GetKeyState(Int32(VK_SHIFT)) < 0 {
                args.handled = true
                self.session.toggleResources()
                return
            }
            // Ctrl+Alt+T brings the ruler of time out or puts it away, as ⌥⌘T does on the Mac.
            if args.key == .t, GetKeyState(Int32(VK_CONTROL)) < 0, GetKeyState(Int32(VK_MENU)) < 0 {
                args.handled = true
                self.toggleVersions()
                return
            }
            // With the ruler out: Escape puts it away, and the arrows step through the versions,
            // unless at now they have something selected to move. Looking back, the canvas's other
            // keys rest.
            let versions = WindowsCore.versions
            if versions.browsing, !(focusedNow is TextBox) {
                let stepping = versions.lookingBack || self.session.selection.isEmpty
                switch args.key {
                case .escape: args.handled = true; versions.leave(); return
                case .left where stepping: args.handled = true; versions.step(-1); return
                case .right where stepping: args.handled = true; versions.step(1); return
                // Commands (Ctrl and a key) still work, as the Mac's menus do.
                default: if versions.lookingBack, GetKeyState(Int32(VK_CONTROL)) >= 0 { return }
                }
            }
            // Ctrl+E exports, as ⌘E does on the Mac.
            if args.key == .e, GetKeyState(Int32(VK_CONTROL)) < 0 {
                args.handled = true
                self.export.open()
                return
            }
            let focused = try? FocusManager.getFocusedElement(self.root.xamlRoot)
            if focused is TextBox { return }
            self.canvas.key(args)
        }
        root.keyUp.addHandler { [weak self] _, args in
            guard let self, let args, !args.handled else { return }
            if args.key == .menu { self.inspector.photoAltChanged() }
            self.canvas.keyUp(args)
        }
    }

    /// The ruler of time out, or away again.
    func toggleVersions() {
        let versions = WindowsCore.versions
        if versions.browsing { versions.leave() } else { versions.browse() }
    }

    /// Plays the prototype from a screen, or from the one a picked layer lies on, or from where
    /// it starts: over the panels and the canvas, under the bar.
    func play(from board: UUID?) {
        guard playing == nil, session.mode == 1,
              let start = WindowsCore.playStart(from: board, selection: session.selection),
              let player = WindowsCore.Player(start: start) else { return }
        let view = PlayerView(player: player)
        view.canvasRect = { [weak self, weak view] r in
            guard let self, let view else { return nil }
            return self.canvas.rect(onCanvas: r, in: view.layer)
        }
        view.landing = { [weak self] id in
            guard let self else { return }
            if let r = player.canvasFrame(of: id) { self.canvas.reveal(r) }
            self.session.select([id], on: WindowsCore.boardIndex(of: id))
        }
        view.closed = { [weak self, weak view] in
            guard let self, let view, self.playing === view else { return }
            self.playing = nil
            self.remove(view.layer)
            self.canvas.takeKeys()
        }
        try? Grid.setRow(view.layer, 1)
        var at: UInt32 = 0
        if (try? root.children.indexOf(export.layer, &at)) == true { try? root.children.insertAt(at, view.layer) } else { root.children.append(view.layer) }
        playing = view
        view.takeKeys()
    }

    private func remove(_ element: UIElement) {
        var k: UInt32 = 0
        if (try? root.children.indexOf(element, &k)) == true { root.children.removeAt(k) }
    }

    /// The zoom menu, as the Mac's: the steps and zooms, then the drawing aids and what goes with them.
    private func zoomEntries() -> [MenuHost.Entry] {
        let canvas = canvas, session = session, z = canvas.currentZoom
        var entries: [MenuHost.Entry] = [
            .item("Zoom In", shortcut: "Ctrl+=") { canvas.zoomStep(in: true) },
            .item("Zoom Out", shortcut: "Ctrl+−") { canvas.zoomStep(in: false) },
            .separator,
            .item("Zoom to Fit", shortcut: "Ctrl+0") { canvas.fit() },
            .item("Zoom to Selection", shortcut: "Ctrl+2", enabled: !session.selection.isEmpty) { canvas.fitSelection() },
            .separator,
        ]
        for (title, value, keys) in [("50%", 0.5, nil), ("100%", 1.0, "Ctrl+1"), ("200%", 2.0, nil), ("400%", 4.0, nil)] as [(String, Double, String?)] {
            entries.append(.item(title, shortcut: keys, checked: abs(z - value) < 0.001) { canvas.zoom(to: value) })
        }
        entries.append(.separator)
        return entries + aidsEntries()
    }

    /// The drawing aids, shown or hidden, as the Mac's Helpers' entries: the zoom menu's end, and
    /// the menu of the rulers' corner.
    private func aidsEntries() -> [MenuHost.Entry] {
        let canvas = canvas, session = session
        func aids() {
            canvas.aidsChanged()
            session.edited(board: nil)
        }
        // The board whose guides Remove Guides takes away: the one selected or that the selection
        // lies on, else the one in the middle of the canvas, else the first, as the Mac's focusedArtboard.
        let boards = WindowsCore.boards().filter { $0.id != nil }
        let middle = canvas.middleOnCanvas
        let board = session.board.flatMap { index in boards.first { $0.index == index }?.id }
            ?? boards.first { $0.frame.contains(middle) }?.id ?? boards.first?.id
        return [
            .item("Rulers", checked: WindowsCore.showsRulers) { WindowsCore.showsRulers.toggle(); aids() },
            .item("Guides", checked: WindowsCore.showsGuides) { WindowsCore.showsGuides.toggle(); aids() },
            .item("Layout Grids", checked: WindowsCore.showsGrids) { WindowsCore.showsGrids.toggle(); aids() },
            .separator,
            .item("Lock Guides", checked: WindowsCore.guidesLocked) { WindowsCore.guidesLocked.toggle(); aids() },
            .item("Remove Guides", enabled: board.map(WindowsCore.hasGuides) == true) {
                if let board { WindowsCore.removeGuides(board) }
                aids()
            },
        ]
    }
}
