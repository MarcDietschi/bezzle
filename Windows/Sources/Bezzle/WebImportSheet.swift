import Foundation
import WinUI
import UWP
import WinSDK
import BezzleCore

/// Bringing a web page in, as the Mac's (Views/WebImportSheet.swift): the address, the widths to
/// read it at, whether cookie banners go, into the design open or as a new one, and the import
/// running; or the page opened in Bezzle's browser first (`WebBrowser`, BrowserWindow.swift), to
/// sign in and click through to the screen wanted. Kept apart from the sheet so the Bezzle menu, a
/// dropped link or home can open it.
@MainActor
final class WebImporting {
    static let shared = WebImporting()

    var address = ""
    var desktop = true
    var tablet = false
    var mobile = false
    var custom = false
    var customWidth: Double = 1280
    var hideBanners = true
    /// The design in front when the sheet opened, which the page can go into beside its artboards.
    private(set) weak var openDesign: WindowsCore.Slot?
    private(set) var openName: String?
    /// Whether the page goes into that design rather than a new one.
    var intoOpen = false
    private(set) var stage: String?
    private(set) var progress: Double?
    private(set) var failure: String?
    private var task: Task<Void, Never>?
    private var cancelled = false

    /// Where the window shows the sheet (home's or the design's page), and where designs are kept.
    var host: (() -> Grid?)?
    var folder: () -> URL = { FileManager.default.temporaryDirectory }
    /// What the window does with a design brought in: opens it, saying what came across.
    var opened: ((URL, WindowsCore.ImportSummary) -> Void)?
    /// What it does with pages brought into an open design: shows them there, selected.
    var broughtIn: ((WindowsCore.Slot, [UUID], WindowsCore.ImportSummary) -> Void)?

    private lazy var sheet = WebImportSheet(model: self)

    /// The Bezzle menu's entry, as the Mac's File menu has it, with its shortcut.
    static var menuEntry: MenuHost.Entry {
        .item(Words.t("Import from a Website…"), shortcut: shortcut) { WebImporting.shared.present() }
    }

    /// The Mac's ⌥⇧⌘I.
    static let shortcut = "Ctrl+Alt+Shift+I"

    /// Whether a key pressed is the shortcut, with Ctrl, Alt and Shift held.
    static func isShortcut(_ key: VirtualKey) -> Bool {
        key == .i && GetKeyState(Int32(VK_CONTROL)) < 0 && GetKeyState(Int32(VK_MENU)) < 0 && GetKeyState(Int32(VK_SHIFT)) < 0
    }

    var running: Bool { progress != nil }
    var showing: Bool { sheet.layer.visibility == .visible }

    /// The sizes chosen, the widest first.
    var sizes: [WindowsCore.WebWidth] {
        var out: [WindowsCore.WebWidth] = []
        if desktop { out.append(.desktop) }
        if custom, customWidth >= 240 { out.append(.custom(customWidth)) }
        if tablet { out.append(.tablet) }
        if mobile { out.append(.mobile) }
        return WindowsCore.webWidths(out)
    }

    var canStart: Bool { !running && WindowsCore.webAddress(address) != nil && !sizes.isEmpty }
    var canBrowse: Bool { !running && WindowsCore.webAddress(address) != nil }

    /// Where the page goes: the design open, while it still is and may be changed.
    private var destination: WindowsCore.Slot? {
        guard intoOpen, let slot = openDesign, slot.isOpen, Tabs.shared.tab(of: slot) != nil,
              !WindowsCore.using(slot, { WindowsCore.isReadOnly }) else { return nil }
        return slot
    }

    /// Opens the sheet, with an address to bring in or the one copied.
    func present(_ address: String? = nil) {
        if let address {
            self.address = address
        } else if !running, let copied = Clipboard.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  copied.lowercased().hasPrefix("http"), WindowsCore.webAddress(copied) != nil {
            self.address = copied
        }
        if !running {
            failure = nil
            let front = Tabs.shared.selected?.slot
            openDesign = front.flatMap { slot in WindowsCore.using(slot) { WindowsCore.isReadOnly } ? nil : slot }
            openName = openDesign.flatMap { slot in Tabs.shared.tab(of: slot)?.name }
            intoOpen = openDesign != nil
        }
        guard let grid = host?() else { return }
        sheet.show(in: grid)
    }

    /// Opens the page in Bezzle's browser, at the widest size chosen, its pages to come into the
    /// design chosen here.
    func browse() {
        guard canBrowse, let url = WindowsCore.webAddress(address) else { return }
        sheet.hide()
        WebBrowser.shared.show(url, width: sizes.first ?? .desktop, into: destination)
    }

    func close() {
        cancel()
        sheet.hide()
    }

    func start() {
        guard !running else { return }
        guard let url = WindowsCore.webAddress(address) else {
            failure = Words.t("That is not a web address Bezzle can open.")
            sheet.refresh()
            return
        }
        failure = nil
        cancelled = false
        stage = Words.t("Loading the page…")
        progress = 0.01
        sheet.refresh()
        let sizes = sizes, hide = hideBanners, folder = folder(), into = destination
        task = Task { @MainActor [weak self] in
            let say: (String, Double) -> Void = { what, done in
                guard let self, !self.cancelled else { return }
                self.stage = what
                self.progress = max(self.progress ?? 0, done)
                self.sheet.refresh()
            }
            do {
                if let into {
                    let (ids, summary) = try await WindowsCore.importWebsite(url, widths: sizes, hideBanners: hide, into: into, progress: say)
                    guard let self, !self.cancelled else { return }
                    self.done(nil)
                    self.sheet.hide()
                    self.broughtIn?(into, ids, summary)
                    return
                }
                let (design, summary) = try await WindowsCore.importWebsite(url, widths: sizes, hideBanners: hide, into: folder, progress: say)
                guard let self, !self.cancelled else { return }
                self.done(nil)
                self.sheet.hide()
                self.opened?(design, summary)
            } catch {
                guard let self, !self.cancelled else { return }
                self.done(error is CancellationError ? nil : (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    func cancel() {
        guard running else { return }
        cancelled = true
        task?.cancel()
        done(nil)
    }

    private func done(_ failure: String?) {
        task = nil
        stage = nil
        progress = nil
        self.failure = failure
        sheet.refresh()
    }
}

/// The sheet over the window where a web page is brought in: a card 440 wide on a dimmed window,
/// laid out as the Mac's.
@MainActor
final class WebImportSheet {
    let layer = Grid()
    private let model: WebImporting
    private let card = Border()
    private let stack = StackPanel()
    private let field = TextBox()
    private let widthField = TextBox()
    private var globe: FrameworkElement?
    private var tiles: [(tile: Border, mark: FrameworkElement, on: () -> Bool)] = []
    private var boxes: [(box: Border, mark: FrameworkElement, on: () -> Bool)] = []
    private let widthWell = Theme.well(radius: 6)
    private let failureText = Theme.text("", size: 12)
    private let primaryBack = Border()
    private let primaryFill = Border()
    private let primaryLabel = Theme.text("", size: 13, weight: 600)
    private let running = Grid()
    private let stageText = Theme.text("", size: 12, ink: 3)
    private var choices: [UIElement] = []
    private var intoSection: StackPanel?
    /// The Into tiles: how each paints itself, its words, and whether they are the open design's name.
    private var intoTiles: [(paint: () -> Void, words: TextBlock, named: Bool)] = []
    private var browseButton: FrameworkElement?

    init(model: WebImporting) {
        self.model = model
        layer.visibility = .collapsed
        layer.background = Theme.brush(0, 0.18)
        layer.pointerPressed.addHandler { [weak self] _, args in
            args?.handled = true
            guard let self, !self.model.running else { return }
            self.model.close()
        }
        layer.keyDown.addHandler { [weak self] _, args in
            guard let self, let args else { return }
            if args.key == .escape {
                args.handled = true
                self.model.close()
            }
        }
        card.width = 440
        card.cornerRadius = Theme.corners(18)
        card.background = Theme.brush(Theme.paper)
        card.borderBrush = Theme.hairline
        card.borderThickness = Theme.inset(0.5)
        card.horizontalAlignment = .center
        card.verticalAlignment = .center
        card.pointerPressed.addHandler { _, args in args?.handled = true }
        stack.spacing = 18
        stack.margin = Theme.inset(24)
        card.child = stack
        layer.children.append(card)
        build()
    }

    /// Over the page it was last shown on, which it leaves for another.
    private var page: Grid?

    func show(in grid: Grid) {
        var at: UInt32 = 0
        if let page, (try? page.children.indexOf(layer, &at)) == true { try? page.children.removeAt(at) }
        try? Grid.setRowSpan(layer, 2)
        try? Grid.setColumnSpan(layer, 4)
        grid.children.append(layer)
        page = grid
        field.text = model.address
        layer.visibility = .visible
        refresh()
        // The address is typed into at once, as on the Mac.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { _ = try? self?.field.focus(.programmatic) }
        }
    }

    func hide() {
        layer.visibility = .collapsed
    }

    // MARK: Building

    private func build() {
        // The title, and the cross that closes.
        let head = Grid()
        let title = Theme.text(Words.t("Import from a Website"), size: 22, weight: 500, serif: true)
        title.verticalAlignment = .center
        head.children.append(title)
        let closer = Pressable(radius: 8) { [weak self] in self?.model.close() }
        closer.box.width = 26
        closer.box.height = 26
        closer.box.horizontalAlignment = .right
        closer.box.child = Glyphs.view(Glyphs.cross(size: 26), size: 26, brush: Theme.ink(2))
        try? ToolTipService.setToolTip(closer.box, Words.t("Close"))
        head.children.append(closer.box)
        stack.children.append(head)

        // The address, in a well with the globe before it.
        let address = section("Address")
        let well = Theme.well(radius: 8)
        well.height = 32
        let row = Grid()
        let auto = ColumnDefinition()
        auto.width = GridLength(value: 1, gridUnitType: .auto)
        let rest = ColumnDefinition()
        rest.width = GridLength(value: 1, gridUnitType: .star)
        row.columnDefinitions.append(auto)
        row.columnDefinitions.append(rest)
        let globe = Glyphs.view(Glyphs.globe(size: 12), size: 12, brush: Theme.ink(3))
        globe.verticalAlignment = .center
        globe.margin = Theme.inset(10, 0, 0, 0)
        self.globe = globe
        row.children.append(globe)
        style(field, size: 13)
        // A long address runs on in its one line (with Windows' clear button while it is typed in).
        field.textWrapping = .noWrap
        field.placeholderText = "example.com"
        field.padding = Theme.inset(7, 6, 10, 0)
        try? Grid.setColumn(field, 1)
        row.children.append(field)
        well.child = row
        field.textChanged.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.model.address = self.field.text
            self.refreshButton()
        }
        field.gotFocus.addHandler { [weak self] _, _ in if let g = self?.globe { Glyphs.paint(g, Theme.ink(2)) } }
        field.lostFocus.addHandler { [weak self] _, _ in if let g = self?.globe { Glyphs.paint(g, Theme.ink(3)) } }
        field.keyDown.addHandler { [weak self] _, args in
            guard let self, let args else { return }
            if args.key == .enter {
                args.handled = true
                if self.model.canStart { self.model.start() }
            }
        }
        address.children.append(well)
        stack.children.append(address)

        // The sizes: three tiles, then a width of one's own.
        let sizes = section("Sizes")
        let tilesRow = Grid()
        for k in 0..<3 {
            let column = ColumnDefinition()
            column.width = GridLength(value: 1, gridUnitType: .star)
            tilesRow.columnDefinitions.append(column)
        }
        tilesRow.columnSpacing = 8
        let offered: [(String, WindowsCore.WebWidth, ReferenceWritableKeyPath<WebImporting, Bool>)] = [
            ("Desktop", .desktop, \.desktop), ("Tablet", .tablet, \.tablet), ("Mobile", .mobile, \.mobile),
        ]
        for (k, (name, width, key)) in offered.enumerated() {
            let tile = sizeTile(name, width: Int(width.width), on: { [unowned self] in self.model[keyPath: key] }) { [unowned self] in
                self.model[keyPath: key].toggle()
                self.refresh()
            }
            try? Grid.setColumn(tile, Int32(k))
            tilesRow.children.append(tile)
        }
        sizes.children.append(tilesRow)
        let another = StackPanel()
        another.orientation = .horizontal
        another.spacing = 8
        another.children.append(checkBox(on: { [unowned self] in self.model.custom }) { [unowned self] in
            self.model.custom.toggle()
            self.refresh()
        })
        another.children.append(tappable(Words.t("Another width")) { [unowned self] in
            self.model.custom.toggle()
            self.refresh()
        })
        widthWell.width = 52 + 14
        widthWell.height = 24
        widthWell.verticalAlignment = .center
        style(widthField, size: 12.5)
        widthField.textAlignment = .right
        widthField.padding = Theme.inset(7, 3, 7, 0)
        widthField.text = String(Int(model.customWidth))
        widthField.textChanged.addHandler { [weak self] _, _ in
            guard let self else { return }
            let digits = self.widthField.text.filter(\.isNumber)
            if let w = Double(digits) { self.model.customWidth = w }
            self.refreshButton()
        }
        widthField.keyDown.addHandler { [weak self] _, args in
            guard let self, let args else { return }
            if args.key == .enter {
                args.handled = true
                if self.model.canStart { self.model.start() }
            }
        }
        widthWell.child = widthField
        another.children.append(widthWell)
        let px = Theme.text("px", size: 12, ink: 3)
        px.verticalAlignment = .center
        another.children.append(px)
        sizes.children.append(another)
        stack.children.append(sizes)
        choices = [tilesRow, another]

        // Into the design open, or a new one, when a design was in front.
        let into = section("Into")
        let intoRow = Grid()
        for _ in 0..<2 {
            let column = ColumnDefinition()
            column.width = GridLength(value: 1, gridUnitType: .star)
            intoRow.columnDefinitions.append(column)
        }
        intoRow.columnSpacing = 8
        let openTile = intoTile(named: true, glyph: Glyphs.stack(size: 12), on: { [unowned self] in self.model.intoOpen }) { [unowned self] in
            self.model.intoOpen = true
            self.refresh()
        }
        let newTile = intoTile(named: false, glyph: Glyphs.plus(size: 12), on: { [unowned self] in !self.model.intoOpen }) { [unowned self] in
            self.model.intoOpen = false
            self.refresh()
        }
        newTile.words.text = Words.t("New Design")
        try? Grid.setColumn(newTile.tile, 1)
        intoRow.children.append(openTile.tile)
        intoRow.children.append(newTile.tile)
        into.children.append(intoRow)
        stack.children.append(into)
        intoSection = into
        choices.append(into)

        // Whether cookie banners go.
        let banners = StackPanel()
        banners.orientation = .horizontal
        banners.spacing = 8
        banners.children.append(checkBox(on: { [unowned self] in self.model.hideBanners }) { [unowned self] in
            self.model.hideBanners.toggle()
            self.refresh()
        })
        banners.children.append(tappable(Words.t("Hide cookie banners")) { [unowned self] in
            self.model.hideBanners.toggle()
            self.refresh()
        })
        stack.children.append(banners)
        choices.append(banners)

        // Why it did not work, when it did not.
        failureText.foreground = Theme.brush(Theme.warning)
        failureText.textWrapping = .wrap
        failureText.lineHeight = 17
        stack.children.append(failureText)

        // Import, filling as it goes, and while it runs what it is doing, with Cancel.
        let foot = StackPanel()
        foot.spacing = 8
        foot.children.append(primary())
        let cancel = ExportSheet.textButton("Cancel") { [weak self] in self?.model.cancel() }
        if let c = cancel as? FrameworkElement { c.horizontalAlignment = .right }
        stageText.textTrimming = .characterEllipsis
        stageText.verticalAlignment = .center
        stageText.margin = Theme.inset(0, 0, 80, 0)
        running.children.append(stageText)
        running.children.append(cancel)
        foot.children.append(running)
        // Or the page in Bezzle's browser first, to sign in or click through to the screen wanted.
        let browse = Controls.cardButton(Words.t("Open the Page…"), glyph: Glyphs.compass(size: 12), height: 28) { [weak self] in
            guard let self, self.model.canBrowse else { return }
            self.model.browse()
        }
        try? ToolTipService.setToolTip(browse, Words.t("Sign in or click through to the screen you want, then import it as it is."))
        browseButton = browse
        foot.children.append(browse)
        stack.children.append(foot)
    }

    /// Where the page goes, the design open or a new one, as the Mac's IntoChoice: its symbol and
    /// name, pencil round it when chosen.
    private func intoTile(named: Bool, glyph: [Glyphs.Part], on: @escaping () -> Bool,
                          _ choose: @escaping @MainActor () -> Void) -> (tile: Border, words: TextBlock) {
        let tile = Border()
        tile.cornerRadius = Theme.corners(7)
        tile.height = 34
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 7
        row.margin = Theme.inset(10, 0, 10, 0)
        row.verticalAlignment = .center
        let picture = Glyphs.view(glyph, size: 12, brush: Theme.ink(3))
        picture.verticalAlignment = .center
        row.children.append(picture)
        let words = Theme.text("", size: 12.5, weight: 500)
        words.textTrimming = .characterEllipsis
        row.children.append(words)
        tile.child = row
        var hovering = false
        // The tile and its symbol held here: WinUI keeps what they are, not these wrappers of them.
        let paint = {
            let isOn = on()
            tile.background = isOn ? Theme.brush(Theme.pencil, Theme.pencilWash) : Theme.brush(Theme.ink, hovering ? 0.07 : 0.04)
            tile.borderBrush = isOn ? Theme.brush(Theme.pencil, 0.8) : Theme.hairline
            tile.borderThickness = Theme.inset(isOn ? 1.2 : 0.5)
            Glyphs.paint(picture, isOn ? Theme.brush(Theme.pencil) : Theme.ink(3))
        }
        tile.pointerEntered.addHandler { _, _ in hovering = true; paint() }
        tile.pointerExited.addHandler { _, _ in hovering = false; paint() }
        tile.pointerPressed.addHandler { _, args in args?.handled = true }
        tile.tapped.addHandler { _, args in
            args?.handled = true
            DispatchQueue.main.async { MainActor.assumeIsolated { choose() } }
        }
        intoTiles.append((paint, words, named))
        paint()
        return (tile, words)
    }

    private func section(_ title: String) -> StackPanel {
        let s = StackPanel()
        s.spacing = 8
        s.children.append(Theme.text(Words.t(title), size: 12.5, weight: 600))
        return s
    }

    private func style(_ box: TextBox, size: Double) {
        box.allowFocusOnInteraction = true
        box.fontFamily = Theme.ui
        box.fontSize = size
        box.minWidth = 0
        box.minHeight = 0
        box.verticalAlignment = .center
        box.borderThickness = Theme.inset(0)
        box.background = Theme.clear
        // One line, without the clear button a one-line field shows on Windows.
        box.textWrapping = .wrap
        box.acceptsReturn = false
        for key in ["TextControlBackground", "TextControlBackgroundPointerOver", "TextControlBackgroundFocused", "TextControlBackgroundDisabled",
                    "TextControlBorderBrush", "TextControlBorderBrushPointerOver", "TextControlBorderBrushFocused", "TextControlBorderBrushDisabled"] {
            _ = box.resources?.insert(key, Theme.clear)
        }
        for key in ["TextControlForeground", "TextControlForegroundPointerOver", "TextControlForegroundFocused", "TextControlForegroundDisabled"] {
            _ = box.resources?.insert(key, Theme.ink(1))
        }
        box.pointerPressed.addHandler { _, args in args?.handled = true }
    }

    /// Words that do what the box beside them does when clicked.
    private func tappable(_ words: String, _ action: @escaping @MainActor () -> Void) -> UIElement {
        let text = Theme.text(words, size: 12.5)
        text.verticalAlignment = .center
        let hit = Border()
        hit.background = Theme.clear
        hit.child = text
        hit.pointerPressed.addHandler { _, args in args?.handled = true }
        hit.tapped.addHandler { _, args in
            args?.handled = true
            DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
        }
        return hit
    }

    /// The Mac's CheckBox: 15 square, radius 4, ink with a tick when on, an outline when off.
    private func checkBox(on: @escaping () -> Bool, _ toggle: @escaping @MainActor () -> Void) -> UIElement {
        let box = Border()
        box.width = 15
        box.height = 15
        box.cornerRadius = Theme.corners(4)
        box.borderThickness = Theme.inset(1)
        box.verticalAlignment = .center
        let mark = Glyphs.view(Glyphs.check(size: 10), size: 10, brush: Theme.brush(Theme.onInk))
        mark.horizontalAlignment = .center
        mark.verticalAlignment = .center
        box.child = mark
        // Easier to hit than it is big, as the Mac's is (4 round it).
        let hit = Border()
        hit.background = Theme.clear
        hit.padding = Theme.inset(4)
        hit.margin = Theme.inset(-4)
        hit.verticalAlignment = .center
        hit.child = box
        hit.pointerPressed.addHandler { _, args in args?.handled = true }
        hit.tapped.addHandler { _, args in
            args?.handled = true
            DispatchQueue.main.async { MainActor.assumeIsolated { toggle() } }
        }
        boxes.append((box, mark, on))
        return hit
    }

    /// One of the sizes a page is read at, chosen or not: its name, its width, a tick when chosen.
    private func sizeTile(_ name: String, width: Int, on: @escaping () -> Bool, _ toggle: @escaping @MainActor () -> Void) -> FrameworkElement {
        let tile = Border()
        tile.cornerRadius = Theme.corners(8)
        let grid = Grid()
        let words = StackPanel()
        words.spacing = 2
        words.margin = Theme.inset(10, 8, 10, 8)
        words.children.append(Theme.text(Words.t(name), size: 12.5, weight: 500))
        words.children.append(Theme.text("\(width) px", size: 11, ink: 3))
        grid.children.append(words)
        let mark = Glyphs.view(Glyphs.check(size: 9), size: 9, brush: Theme.brush(Theme.pencil))
        mark.horizontalAlignment = .right
        mark.verticalAlignment = .top
        mark.margin = Theme.inset(0, 8, 8, 0)
        grid.children.append(mark)
        tile.child = grid
        var hovering = false
        let paint = { [weak tile, weak mark] in
            guard let tile, let mark else { return }
            let isOn = on()
            tile.background = isOn ? Theme.brush(Theme.pencil, Theme.pencilWash) : Theme.brush(Theme.ink, hovering ? 0.07 : 0.04)
            tile.borderBrush = isOn ? Theme.brush(Theme.pencil, 0.8) : Theme.hairline
            tile.borderThickness = Theme.inset(isOn ? 1.2 : 0.5)
            mark.opacity = isOn ? 1 : 0
        }
        tile.pointerEntered.addHandler { _, _ in hovering = true; paint() }
        tile.pointerExited.addHandler { _, _ in hovering = false; paint() }
        tile.pointerPressed.addHandler { _, args in args?.handled = true }
        tile.tapped.addHandler { _, args in
            args?.handled = true
            DispatchQueue.main.async { MainActor.assumeIsolated { toggle() } }
        }
        tiles.append((tile, mark, on))
        paint()
        return tile
    }

    /// The Mac's PrimaryButton: 38 tall, radius 10, ink with the paper's colour on it, filling
    /// with pencil from the left as the work goes.
    private func primary() -> UIElement {
        let press = Pressable(radius: 10) { [weak self] in
            guard let self, self.model.canStart else { return }
            self.model.start()
        }
        press.hoverWash = 0
        let box = Grid()
        box.height = 38
        primaryBack.cornerRadius = Theme.corners(10)
        box.children.append(primaryBack)
        primaryFill.horizontalAlignment = .left
        primaryFill.cornerRadius = Theme.corners(10)
        primaryFill.background = Theme.brush(Theme.pencil)
        box.children.append(primaryFill)
        primaryLabel.horizontalAlignment = .center
        primaryLabel.verticalAlignment = .center
        box.children.append(primaryLabel)
        press.box.child = box
        press.box.pointerEntered.addHandler { [weak self] _, _ in
            guard let self, self.model.canStart else { return }
            self.primaryBack.background = Theme.brush(Theme.ink, 0.88)
        }
        press.box.pointerExited.addHandler { [weak self] _, _ in self?.refreshButton() }
        return press.box
    }

    // MARK: Showing what is so

    func refresh() {
        for (tile, mark, on) in tiles {
            let isOn = on()
            tile.background = isOn ? Theme.brush(Theme.pencil, Theme.pencilWash) : Theme.brush(Theme.ink, 0.04)
            tile.borderBrush = isOn ? Theme.brush(Theme.pencil, 0.8) : Theme.hairline
            tile.borderThickness = Theme.inset(isOn ? 1.2 : 0.5)
            mark.opacity = isOn ? 1 : 0
        }
        for (box, mark, on) in boxes {
            let isOn = on()
            box.background = isOn ? Theme.ink(1) : Theme.clear
            box.borderBrush = isOn ? Theme.ink(1) : Theme.ink(3)
            mark.opacity = isOn ? 1 : 0
        }
        widthWell.opacity = model.custom ? 1 : 0.45
        widthField.isEnabled = model.custom && !model.running
        field.isEnabled = !model.running
        for choice in choices {
            choice.opacity = model.running ? 0.5 : 1
            choice.isHitTestVisible = !model.running
        }
        if let failure = model.failure {
            failureText.text = failure
            failureText.visibility = .visible
        } else {
            failureText.visibility = .collapsed
        }
        stageText.text = model.stage ?? ""
        running.visibility = model.running ? .visible : .collapsed
        intoSection?.visibility = model.openName == nil ? .collapsed : .visible
        for tile in intoTiles {
            if tile.named { tile.words.text = model.openName ?? "" }
            tile.paint()
        }
        browseButton?.visibility = model.running ? .collapsed : .visible
        browseButton?.opacity = model.canBrowse ? 1 : 0.45
        refreshButton()
    }

    private func refreshButton() {
        let enabled = model.canStart
        browseButton?.opacity = model.canBrowse ? 1 : 0.45
        primaryBack.background = Theme.brush(Theme.ink, enabled ? 1 : 0.22)
        primaryLabel.text = Words.t(model.running ? "Importing…" : "Import")
        primaryLabel.foreground = Theme.brush(Theme.paper, enabled ? 1 : 0.8)
        if let progress = model.progress {
            primaryFill.visibility = .visible
            primaryFill.width = max(14, 392 * progress)
        } else {
            primaryFill.visibility = .collapsed
        }
    }
}

extension Glyphs {
    /// A globe: its rim, a meridian and the lines of latitude across it, as the Mac's globe
    /// symbol, drawn in Bezzle's own hand.
    static func globe(size s: Double = 12) -> [Part] {
        var p = PathData()
        let c = s / 2, r = s * 0.44
        p.ellipse(c - r, c - r, r * 2, r * 2)
        p.ellipse(c - r * 0.42, c - r, r * 0.84, r * 2)
        p.move(c - r, c); p.line(c + r, c)
        p.move(c - r * 0.86, c - r * 0.5); p.line(c + r * 0.86, c - r * 0.5)
        p.move(c - r * 0.86, c + r * 0.5); p.line(c + r * 0.86, c + r * 0.5)
        return [Part(data: p.d, mode: .stroke, width: 1.1)]
    }
}
