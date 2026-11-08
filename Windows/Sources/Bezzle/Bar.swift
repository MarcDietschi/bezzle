import Foundation
import WinUI
import UWP
import BezzleCore

/// The bar across the top of the window, as the Mac's (Views/TabBar.swift, Workspace.swift): the
/// tabs (home, the open designs and "+", which the window puts in `tabsHolder` while this design
/// is in front), room to drag the window by, then the zoom, Versions, Share…, the mode switch and
/// Export…. Windows' own caption buttons sit at its right end.
@MainActor
final class Bar {
    let root = Grid()
    /// The empty middle, which drags the window (Window.setTitleBar).
    let dragArea = Border()
    /// Where the tabs go (`TabStrip`).
    let tabsHolder = Border()
    /// What is to do with the design, at the right, which the tabs leave room for.
    let right = StackPanel()
    private let session: DesignSession
    /// How the design is shared, and Share… (ShareViews.swift).
    let sharing: ShareControls
    private let zoomLabel = Theme.text("50%", size: 12, ink: 1)
    private var segments: [(box: Border, label: TextBlock)] = []

    /// How much room Windows' caption buttons take at the right.
    static let captionRoom = 140.0

    /// What Export… does: the window opens its Export sheet. Seen as a prototype, the button
    /// turns into Play, as the Mac's ModeAction.
    var onExport: (() -> Void)?
    var onPlay: (() -> Void)?
    private let action = Border()
    private var actionMode = -1
    /// Bezzle's own menus, and what the zoom menu holds.
    var menus: MenuHost?
    var zoomEntries: (() -> [MenuHost.Entry])?

    init(session: DesignSession) {
        self.session = session
        sharing = ShareControls(session: session)
        root.height = Theme.barHeight
        for width in [GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star),
                      GridLength(value: 1, gridUnitType: .auto), GridLength(value: Self.captionRoom, gridUnitType: .pixel)] {
            let column = ColumnDefinition()
            column.width = width
            root.columnDefinitions.append(column)
        }

        // Left: the tabs, home first, as on the Mac 14 points from what follows.
        tabsHolder.verticalAlignment = .center
        tabsHolder.margin = Theme.inset(16, 0, 14, 0)
        root.children.append(tabsHolder)

        dragArea.background = Theme.clear
        try? Grid.setColumn(dragArea, 1)
        root.children.append(dragArea)

        // Right: zoom, Versions, Share…, the modes, Export….
        right.orientation = .horizontal
        right.spacing = 10
        right.verticalAlignment = .center
        right.margin = Theme.inset(0, 0, 8, 0)
        right.children.append(sharing.tag)
        right.children.append(zoomMenu())
        right.children.append(versionsButton())
        right.children.append(sharing.button)
        right.children.append(modeSwitch())
        right.children.append(actionButton())
        try? Grid.setColumn(right, 2)
        root.children.append(right)

        session.listen { [weak self] in self?.show() }
        show()
    }

    private func show() {
        zoomLabel.text = "\(Int((session.zoom * 100).rounded()))%"
        if actionMode != session.mode { paintAction() }
        paintModes()
    }

    /// Export…, or seen as a prototype, Play: one button turning from a card into the pencil's blue.
    private func actionButton() -> UIElement {
        action.height = 28
        action.cornerRadius = Theme.corners(8)
        action.pointerPressed.addHandler { _, args in args?.handled = true }
        action.tapped.addHandler { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.session.mode == 1 { self.onPlay?() } else { self.onExport?() }
                }
            }
        }
        paintAction()
        return action
    }

    private func paintAction() {
        actionMode = session.mode
        let play = session.mode == 1
        action.background = Theme.brush(play ? Theme.pencil : Theme.card)
        action.borderBrush = play ? Theme.clear : Theme.hairline
        action.borderThickness = Theme.inset(play ? 0 : 0.5)
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 6
        row.margin = Theme.inset(play ? 11 : 14, 0, play ? 13 : 14, 0)
        row.verticalAlignment = .center
        if play { row.children.append(Glyphs.view(Glyphs.play(size: 12), size: 12, brush: Theme.brush(Theme.onInk))) }
        let title = Theme.text(Words.t(play ? "Play" : "Export…"), size: play ? 12.5 : 12, weight: play ? 600 : 500)
        if play { title.foreground = Theme.brush(Theme.onInk) }
        row.children.append(title)
        action.child = row
        try? ToolTipService.setToolTip(action, Words.t(play ? "Play the prototype from where it starts, or from the picked screen  Ctrl+Enter" : "Export  Ctrl+E"))
    }

    /// Chooses another folder for designs (the app's).
    static var chooseDesignsFolder: (() -> Void)?
    /// Asks for a file from Adobe XD, Figma, Sketch or Photoshop to bring in, each in a tab of its own.
    static var bringIn: (() -> Void)?

    /// The Bezzle menu, as the Mac's app menu and File menu have it, which on Windows hangs from
    /// the home tab: bringing designs in from other apps, whether AI assistants may work in the
    /// app and how to connect one, the designs folder, and the design in front in Explorer.
    /// With a design in front, its spelling's entries too (the Mac's Edit › Spelling and Grammar).
    static func appEntries(front url: URL?, spelling: [MenuHost.Entry] = []) -> [MenuHost.Entry] {
        // A design here is a folder, which Open (Ctrl+O) picks, so files from other apps come in by their own entry.
        [.item(Words.t("Bring In a Design…"), shortcut: "Ctrl+Shift+I") { Bar.bringIn?() }, WebImporting.menuEntry, .separator]
            + (spelling.isEmpty ? [] : spelling + [.separator]) + appEntries(showing: url)
    }

    private static func appEntries(showing url: URL?) -> [MenuHost.Entry] {
        let server = MCPServer.shared
        let on = AIControl.allowed
        var entries: [MenuHost.Entry] = [.item(Words.t("Allow AI Control"), checked: on) { AIControl.allowed = !on }]
        if on, let failure = server.failure { entries.append(.note(Words.t("AI control is off: %@", failure))) }
        entries.append(.separator)
        let address = server.address
        entries.append(.item(Words.t("Copy Claude Code Command"), enabled: on) {
            Clipboard.copyText("claude mcp add --transport http --scope user bezzle \(address)")
        })
        // Codex in the terminal and in the ChatGPT app, which share their servers.
        entries.append(.item(Words.t("Copy Codex Command"), enabled: on) { Clipboard.copyText("codex mcp add bezzle --url \(address)") })
        entries.append(.item(Words.t("Copy Server Address"), enabled: on) { Clipboard.copyText(address) })
        entries.append(.separator)
        entries.append(.item(Words.t("Designs Folder…")) { Bar.chooseDesignsFolder?() })
        // The design in front, picked out in Explorer.
        if let url {
            entries.append(.separator)
            entries.append(.item(Words.t("Show in Explorer")) {
                // Picked out in the folder it is in: a design is a folder itself.
                let explorer = Process()
                explorer.executableURL = URL(fileURLWithPath: "C:\\Windows\\explorer.exe")
                explorer.arguments = ["/select," + url.path.replacingOccurrences(of: "/", with: "\\")]
                try? explorer.run()
            })
        }
        return entries
    }

    private func zoomMenu() -> UIElement {
        var holder: Border?
        let button = Pressable(radius: 8) { [weak self] in
            guard let self, let menus = self.menus, let entries = self.zoomEntries, let holder else { return }
            menus.show(below: holder, width: 220, entries: entries())
        }
        holder = button.box
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 4
        row.margin = Theme.inset(8, 4, 6, 4)
        row.children.append(zoomLabel)
        row.children.append(Glyphs.view(Glyphs.chevron(open: true, size: 9), size: 9, brush: Theme.ink(3)))
        button.box.child = row
        return button.box
    }

    /// Brings the ruler of time out or puts it away.
    var onVersions: (() -> Void)?
    private let versionsBox = Border()

    /// The time ruler's switch: the pencil's, on its wash, while the ruler is out.
    private func versionsButton() -> UIElement {
        let button = Pressable(radius: 8) { [weak self] in self?.onVersions?() }
        button.box.width = 30
        button.box.height = 28
        versionsBox.cornerRadius = Theme.corners(8)
        versionsBox.child = centred(Glyphs.view(Glyphs.history(), size: 16, brush: Theme.ink(2)))
        button.box.child = versionsBox
        try? ToolTipService.setToolTip(button.box, Words.t("Versions") + "  Ctrl+Alt+T")
        return button.box
    }

    func versionsChanged() {
        let out = WindowsCore.versions.browsing
        versionsBox.background = out ? Theme.brush(Theme.pencil, Theme.pencilWash) : Theme.clear
        versionsBox.child = centred(Glyphs.view(Glyphs.history(), size: 16, brush: out ? Theme.brush(Theme.pencil) : Theme.ink(2)))
    }

    private func centred(_ e: FrameworkElement) -> FrameworkElement {
        e.horizontalAlignment = .center
        e.verticalAlignment = .center
        return e
    }

    private func iconButton(_ parts: [Glyphs.Part]) -> UIElement {
        let button = Pressable(radius: 8) {}
        button.box.width = 28
        button.box.height = 28
        button.box.child = Glyphs.view(parts, size: 16, brush: Theme.ink(2))
        return button.box
    }

    /// A button as `.card()` draws one: 28 tall, radius 8.
    private func cardButton(_ title: String, glyph: [Glyphs.Part]?, _ action: (@MainActor () -> Void)? = nil) -> UIElement {
        let card = Theme.card(radius: 8)
        card.height = 28
        if let action {
            card.pointerPressed.addHandler { _, args in args?.handled = true }
            card.tapped.addHandler { _, _ in DispatchQueue.main.async { MainActor.assumeIsolated { action() } } }
        }
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 6
        row.margin = Theme.inset(10, 0, 12, 0)
        row.verticalAlignment = .center
        if let glyph { row.children.append(Glyphs.view(glyph, size: 14, brush: Theme.ink(1))) }
        row.children.append(Theme.text(Words.t(title), size: 12, weight: 500))
        card.child = row
        return card
    }

    /// Design | Prototype | Inspect: segments 24 tall in a well of radius 9, the one on a card of
    /// radius 7.
    private func modeSwitch() -> UIElement {
        let well = Theme.well(radius: 9)
        well.height = 30
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 2
        row.margin = Theme.inset(3)
        for (k, title) in ["Design", "Prototype", "Inspect"].map(Words.t).enumerated() {
            let segment = Border()
            segment.height = 24
            segment.cornerRadius = Theme.corners(7)
            let label = Theme.text(title, size: 12, weight: 500, ink: 2)
            label.margin = Theme.inset(10, 0, 10, 0)
            segment.child = label
            segment.tapped.addHandler { [weak self] _, _ in
                self?.session.mode = k
                self?.paintModes()
            }
            row.children.append(segment)
            segments.append((segment, label))
        }
        well.child = row
        paintModes()
        return well
    }

    private func paintModes() {
        for (k, s) in segments.enumerated() {
            let on = k == session.mode
            s.box.background = on ? Theme.brush(Theme.card) : Theme.clear
            s.box.borderBrush = on ? Theme.hairline : Theme.clear
            s.box.borderThickness = Theme.inset(on ? 0.5 : 0)
            s.label.foreground = Theme.ink(on ? 1 : 2)
        }
    }
}
