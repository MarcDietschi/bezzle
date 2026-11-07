import Foundation
import WinUI
import UWP
import WinSDK
import BezzleCore

/// Home, as the Mac's (Views/HomeView.swift, HomeStage.swift; numbers in DESIGN.md): the bar
/// with the home tab, Search and Open…; the greeting; the stage with the families of sizes, a
/// click on one making a new design of it; and the designs in the Designs folder.
///
/// For now the sizes stand as sheets of their proportions; the Mac draws each as its device
/// (HomeStage.swift's SizeForm), which is to come.
@MainActor
final class HomeView {
    let root = Grid()
    let dragArea = Border()
    /// Bezzle's own menus, over the home screen: the Bezzle menu.
    private let menus = MenuHost()
    /// What home's search looks for among the designs' names.
    private var query = ""
    /// The designs' pictures drawn so far, by design, size and when it was last changed.
    private var pictures: [String: WriteableBitmap] = [:]
    private let folder: URL
    private let open: (URL) -> Void
    private let page = StackPanel()
    private let stage = Border()
    private let lineup = StackPanel()
    private let tabs = StackPanel()
    private let designs = StackPanel()
    private var family = 0
    private let sizes = WindowsCore.sizes().flatMap { $0.families }
    private var pixelScale = 1.0

    init(folder: URL, open: @escaping (URL) -> Void) {
        self.folder = folder
        self.open = open
        root.background = Theme.brush(Theme.paper)
        let barRow = RowDefinition()
        barRow.height = GridLength(value: Theme.barHeight, gridUnitType: .pixel)
        let pageRow = RowDefinition()
        pageRow.height = GridLength(value: 1, gridUnitType: .star)
        root.rowDefinitions.append(barRow)
        root.rowDefinitions.append(pageRow)
        root.children.append(bar())

        page.maxWidth = 1240
        page.margin = Theme.inset(40, 14, 40, 56)
        page.spacing = 26
        page.children.append(greeting())
        page.children.append(stageView())
        page.children.append(designsHeading())
        page.children.append(designs)
        let scroll = ScrollView()
        scroll.content = page
        try? Grid.setRow(scroll, 1)
        root.children.append(scroll)
        root.loaded.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.pixelScale = self.root.xamlRoot?.rasterizationScale ?? 1
            self.showDesigns()
        }
        root.sizeChanged.addHandler { [weak self] _, _ in self?.showDesigns() }
        try? Grid.setRowSpan(menus.layer, 2)
        root.children.append(menus.layer)
        takeDrops()
    }

    // MARK: Bar

    private func bar() -> UIElement {
        let bar = Grid()
        for width in [GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star),
                      GridLength(value: 1, gridUnitType: .auto), GridLength(value: Bar.captionRoom, gridUnitType: .pixel)] {
            let column = ColumnDefinition()
            column.width = width
            bar.columnDefinitions.append(column)
        }
        let home = Theme.card(radius: 9)
        home.height = 30
        home.verticalAlignment = .center
        home.margin = Theme.inset(16, 0, 0, 0)
        let word = Theme.text("Bezzle", size: 15, weight: 600, serif: true)
        word.margin = Theme.inset(10, 0, 10, 0)
        home.child = word
        // The Bezzle menu, as on a design's bar.
        home.pointerPressed.addHandler { _, args in args?.handled = true }
        home.tapped.addHandler { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menus.show(below: home, width: 260, entries: Bar.appEntries())
                }
            }
        }
        bar.children.append(home)

        dragArea.background = Theme.clear
        try? Grid.setColumn(dragArea, 1)
        bar.children.append(dragArea)

        let right = StackPanel()
        right.orientation = .horizontal
        right.spacing = 10
        right.verticalAlignment = .center
        right.margin = Theme.inset(0, 0, 8, 0)
        let search = Theme.well(radius: 8)
        search.width = 200
        search.height = 28
        let field = TextBox()
        field.placeholderText = Words.t("Search")
        field.fontFamily = Theme.ui
        field.fontSize = 12
        field.background = Theme.clear
        field.borderThickness = Theme.inset(0)
        field.padding = Theme.inset(10, 5, 10, 0)
        field.minHeight = 26
        search.child = field
        // The designs whose names have what is typed in them, as it is typed.
        field.textChanged.addHandler { [weak self] sender, _ in
            guard let self, let text = (sender as? TextBox)?.text else { return }
            self.query = text.trimmingCharacters(in: .whitespaces)
            // Once the typing is over: pictures made inside the field's event stay blank.
            DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh() } }
        }
        right.children.append(search)
        // A design here is a folder, which Open… picks: files from other apps come in by their own button.
        let bringIn = Theme.card(radius: 8)
        bringIn.height = 28
        let bringLabel = Theme.text(Words.t("Bring In…"), size: 12, weight: 500)
        bringLabel.margin = Theme.inset(12, 0, 12, 0)
        bringIn.child = bringLabel
        bringIn.tapped.addHandler { [weak self] _, _ in self?.chooseAndBringIn() }
        right.children.append(bringIn)
        let openButton = Theme.card(radius: 8)
        openButton.height = 28
        let label = Theme.text(Words.t("Open…"), size: 12, weight: 500)
        label.margin = Theme.inset(12, 0, 12, 0)
        openButton.child = label
        openButton.tapped.addHandler { [weak self] _, _ in self?.chooseAndOpen() }
        right.children.append(openButton)
        try? Grid.setColumn(right, 2)
        bar.children.append(right)
        return bar
    }

    func chooseAndOpen() {
        if let url = FileDialogs.chooseDesign(startingIn: folder) { open(url) }
    }

    func chooseAndBringIn() {
        if let url = FileDialogs.chooseFileToBringIn() { open(url) }
    }

    // MARK: Files dropped on home

    /// StandardDataFormats.StorageItems, which the bindings leave out: files, as Explorer drags them.
    private static let storageItems = "Shell IDList Array"

    /// Designs and files from other apps dropped anywhere on home open, as on the Mac: the first
    /// of them, as one design shows at a time here.
    private func takeDrops() {
        root.allowDrop = true
        root.dragOver.addHandler { _, args in
            guard let args, let view = args.dataView else { return }
            args.acceptedOperation = (try? view.contains(Self.storageItems)) == true ? .copy : .none
        }
        root.drop.addHandler { [weak self] _, args in
            guard let args, let view = args.dataView, (try? view.contains(Self.storageItems)) == true else { return }
            let deferral = try? args.getDeferral()
            Task { @MainActor [weak self] in
                defer { try? deferral?.complete() }
                guard let items = try? await view.getStorageItemsAsync()?.get() else { return }
                var urls: [URL] = []
                for k in 0..<items.size {
                    if let item = (try? items.getAt(k)) ?? nil, !item.path.isEmpty { urls.append(URL(fileURLWithPath: item.path)) }
                }
                guard let first = urls.first(where: { $0.pathExtension.lowercased() == "bezzle" || WindowsCore.imports($0) }) else { return }
                // After the drop is over: opening replaces home, which the drop is still on.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.open(first) } }
            }
        }
    }

    // MARK: Greeting and stage

    private func greeting() -> UIElement {
        let line = StackPanel()
        line.orientation = .horizontal
        line.horizontalAlignment = .center
        line.spacing = 10
        let hour = Calendar.current.component(.hour, from: Date())
        let hello = hour >= 5 && hour < 12 ? "Good morning." : hour >= 12 && hour < 18 ? "Good afternoon." : "Good evening."
        line.children.append(Theme.text(Words.t(hello), size: 34, weight: 500, serif: true))
        line.children.append(Theme.text(Words.t("What are you designing today?"), size: 34, weight: 500, ink: 3, serif: true))
        line.margin = Theme.inset(0, 18, 0, 0)
        return line
    }

    /// The stage: the families' tabs, and the sizes of the one chosen standing on it, on the
    /// table lit as the Mac lights it (its Stage and Daylight).
    private let table = Image()
    private var tableSize = (w: 0, h: 0)

    private func stageView() -> UIElement {
        let holder = Grid()
        holder.cornerRadius = Theme.corners(20)
        table.stretch = .fill
        holder.children.append(table)
        stage.cornerRadius = Theme.corners(20)
        stage.padding = Theme.inset(24, 18, 24, 0)
        let inside = StackPanel()
        tabs.orientation = .horizontal
        tabs.spacing = 4
        tabs.horizontalAlignment = .center
        inside.children.append(tabs)
        lineup.orientation = .horizontal
        lineup.spacing = 26
        lineup.horizontalAlignment = .center
        lineup.margin = Theme.inset(30, 34, 30, 26)
        inside.children.append(lineup)
        stage.child = inside
        holder.children.append(stage)
        holder.sizeChanged.addHandler { [weak self] _, _ in self?.lightTable(holder) }
        showFamily()
        return holder
    }

    private func lightTable(_ holder: Grid) {
        let w = Int((holder.actualWidth * pixelScale).rounded()), h = Int((holder.actualHeight * pixelScale).rounded())
        guard w > 0, h > 0, (w, h) != tableSize else { return }
        tableSize = (w, h)
        let bitmap = WriteableBitmap(Int32(w), Int32(h))
        if let pixels = (try? bitmap.pixelBuffer.buffer).flatMap({ $0 }) {
            _ = WindowsCore.stage(width: w, height: h, scale: pixelScale, table: Theme.table, dark: Theme.dark, into: UnsafeMutableRawPointer(pixels))
        }
        try? bitmap.invalidate()
        table.source = bitmap
    }

    /// How tall the tallest thing stands, and how wide the widest may (the Mac's Lineup).
    private static let tallest = 150.0
    private static let widest = 300.0

    private func showFamily() {
        tabs.children.clear()
        var kindBefore: String?
        for (k, f) in sizes.enumerated() {
            // A hairline between the kinds: devices, social media, print and slides.
            let kind = kinds[k]
            if let before = kindBefore, before != kind {
                let line = Border()
                line.width = 1
                line.height = 16
                line.background = Theme.hairline
                line.margin = Theme.inset(6, 0, 6, 0)
                tabs.children.append(line)
            }
            kindBefore = kind
            let tab = Border()
            tab.height = 28
            tab.cornerRadius = Theme.corners(14)
            let on = k == family
            tab.background = on ? Theme.brush(Theme.card) : Theme.clear
            tab.borderBrush = on ? Theme.hairline : Theme.clear
            tab.borderThickness = Theme.inset(on ? 0.5 : 0)
            let label = Theme.text(Words.t(f.name), size: 12, weight: 500, ink: on ? 1 : 2)
            label.margin = Theme.inset(12, 0, 12, 0)
            tab.child = label
            tab.tapped.addHandler { [weak self] _, _ in self?.family = k; self?.showFamily() }
            tabs.children.append(tab)
        }

        lineup.children.clear()
        let all = sizes[family].sizes
        let forms = all.map { Devices.form(group: $0.group, name: $0.name, width: $0.width, height: $0.height) }
        let drawn = zip(all, forms).map { size, form in (w: size.width * Devices.density(form), h: size.height * Devices.density(form)) }
        // One scale for the whole family, as large as lets its tallest and widest thing fit.
        let first = min(Self.tallest / (drawn.map(\.h).max() ?? 1), Self.widest / (drawn.map(\.w).max() ?? 1))
        var most = (w: 0.0, h: 0.0)
        for (form, d) in zip(forms, drawn) {
            let m = Devices.metrics(form, CGSize(width: d.w * first, height: d.h * first))
            most = (max(most.w, Double(m.size.width)), max(most.h, Double(m.size.height)))
        }
        let scale = first * min(Self.tallest / max(most.h, 1), Self.widest / max(most.w, 1))
        for ((size, form), d) in zip(zip(all, forms), drawn) {
            lineup.children.append(stand(size, form: form, screen: CGSize(width: max((d.w * scale).rounded(), 8), height: max((d.h * scale).rounded(), 8))))
        }
    }

    private lazy var kinds: [String] = WindowsCore.sizes().flatMap { kind in kind.families.map { _ in kind.kind } }

    /// A size standing on the table as the thing it is for, its name and size under it; pointed
    /// at, it lifts, its screen outlined in pencil with a plus on it; a click starts a design.
    private func stand(_ size: WindowsCore.Size, form: Devices.Form, screen: CGSize) -> UIElement {
        let (figure, m) = Devices.view(form, screen: screen)
        let column = StackPanel()
        column.spacing = 14
        let room = Grid()
        room.height = Self.tallest
        room.width = max(Double(m.size.width), 60)
        // Its shadow on the table, and the thing standing on it.
        let shadow = Image()
        shadow.isHitTestVisible = false
        shadow.verticalAlignment = .bottom
        shadow.horizontalAlignment = .center
        let sw = Int((Double(m.size.width) * 0.9 * pixelScale).rounded()), sh = Int((3 * pixelScale).rounded())
        _ = WindowsCore.artboardShadow(width: max(sw, 1), height: max(sh, 1), scale: pixelScale, colour: Theme.shadow) { w, h, pad in
            let bitmap = WriteableBitmap(Int32(w), Int32(h))
            shadow.source = bitmap
            shadow.width = Double(w) / pixelScale
            shadow.height = Double(h) / pixelScale
            shadow.margin = Theme.inset(0, 0, 0, -Double(pad) / pixelScale)
            return (try? bitmap.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        (shadow.source as? WriteableBitmap).map { try? $0.invalidate() }
        room.children.append(shadow)
        let thing = Grid()
        thing.width = Double(m.size.width)
        thing.height = Double(m.size.height)
        thing.verticalAlignment = .bottom
        thing.horizontalAlignment = .center
        thing.children.append(figure)
        // The pencil round its screen, with a plus, for when it is pointed at.
        let ring = Rectangle()
        ring.width = Double(m.screen.width)
        ring.height = Double(m.screen.height)
        ring.radiusX = m.radius
        ring.radiusY = m.radius
        ring.stroke = Theme.brush(Theme.pencil)
        ring.strokeThickness = 1.5
        ring.horizontalAlignment = .left
        ring.verticalAlignment = .top
        ring.margin = Theme.inset(Double(m.screen.minX), Double(m.screen.minY), 0, 0)
        ring.opacity = 0
        thing.children.append(ring)
        let badge = Border()
        badge.width = 22
        badge.height = 22
        badge.cornerRadius = Theme.corners(11)
        badge.background = Theme.brush(Theme.pencil)
        badge.child = Glyphs.view(Glyphs.plus(size: 22), size: 22, brush: Theme.brush(0xFFFFFF))
        badge.horizontalAlignment = .left
        badge.verticalAlignment = .top
        badge.margin = Theme.inset(Double(m.screen.midX) - 11, Double(m.screen.midY) - 11, 0, 0)
        badge.opacity = 0
        thing.children.append(badge)
        room.children.append(thing)
        column.children.append(room)

        let words = StackPanel()
        words.spacing = 2
        let title = Theme.text(Words.t(size.name), size: 12, weight: 500)
        title.horizontalAlignment = .center
        title.maxWidth = max(room.width + 30, 90)
        let numbers = Theme.text("\(Int(size.width)) × \(Int(size.height))", size: 11, ink: 3)
        numbers.horizontalAlignment = .center
        words.children.append(title)
        words.children.append(numbers)
        column.children.append(words)

        let lift = CompositeTransform()
        thing.renderTransform = lift
        let pick = Pressable(radius: 10) { [weak self] in self?.make(size) }
        pick.hoverWash = 0
        pick.box.child = column
        pick.box.pointerEntered.addHandler { _, _ in
            lift.translateY = -5
            ring.opacity = 1
            badge.opacity = 1
            title.foreground = Theme.brush(Theme.pencil)
            numbers.foreground = Theme.brush(Theme.pencil, 0.75)
        }
        pick.box.pointerExited.addHandler { _, _ in
            lift.translateY = 0
            ring.opacity = 0
            badge.opacity = 0
            title.foreground = Theme.ink(1)
            numbers.foreground = Theme.ink(3)
        }
        try? ToolTipService.setToolTip(pick.box, Words.t("Start a design %lld by %lld", Int(size.width), Int(size.height)))
        return pick.box
    }

    private func make(_ size: WindowsCore.Size) {
        if let url = try? WindowsCore.createDesign(in: folder, size: size) { open(url) }
    }

    // MARK: Your designs

    private func designsHeading() -> UIElement {
        let heading = Theme.text(Words.t("Your designs"), size: 22, weight: 500, serif: true)
        heading.margin = Theme.inset(0, 12, 0, 0)
        return heading
    }

    private var shownWidth = 0.0

    /// The designs in the Designs folder, newest first, in a grid as wide as the page: tiles at
    /// least 220 wide, 22 apart, thumbnails radius 12 at 480 × 300, names in the serif.
    private func showDesigns() {
        let width = min(1240, max(300, root.actualWidth - 80))
        guard abs(width - shownWidth) > 1 else { return }
        shownWidth = width
        designs.children.clear()
        designs.spacing = 24
        let urls = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "bezzle" }
            .filter { query.isEmpty || $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(query) }
            .sorted { (date($0) ?? .distantPast) > (date($1) ?? .distantPast) }
        let columns = max(1, Int((width + 22) / (220 + 22)))
        let tile = (width - Double(columns - 1) * 22) / Double(columns)
        var row: StackPanel?
        for (k, url) in urls.enumerated() {
            if k % columns == 0 {
                let r = StackPanel()
                r.orientation = .horizontal
                r.spacing = 22
                designs.children.append(r)
                row = r
            }
            row?.children.append(card(url, width: tile))
        }
    }

    private func date(_ url: URL) -> Date? {
        let document = url.appendingPathComponent("document.json")
        return (try? document.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func card(_ url: URL, width: Double) -> UIElement {
        let column = StackPanel()
        column.spacing = 10
        column.width = width
        let frame = Border()
        frame.width = width
        frame.height = width * 300 / 480
        frame.cornerRadius = Theme.corners(12)
        frame.background = Theme.brush(Theme.table)
        frame.borderBrush = Theme.hairline
        frame.borderThickness = Theme.inset(0.5)
        let image = Image()
        image.stretch = .uniformToFill
        image.verticalAlignment = .top
        frame.child = image
        // Drawn once the page shows, one after another, so home comes up at once; kept for when
        // the list is made again (a search, say) while the design and the size are as they were.
        let scale = pixelScale
        let key = "\(url.path)|\(Int(width))|\(date(url)?.timeIntervalSince1970 ?? 0)"
        if let kept = pictures[key] {
            image.source = kept
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    var bitmap: WriteableBitmap?
                    _ = WindowsCore.thumbnail(of: url, width: width, height: width * 300 / 480, scale: scale) { w, h in
                        bitmap = WriteableBitmap(Int32(w), Int32(h))
                        return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
                    }
                    try? bitmap?.invalidate()
                    image.source = bitmap
                    if let bitmap { self.pictures[key] = bitmap }
                }
            }
        }
        column.children.append(frame)
        let name = Theme.text(url.deletingPathExtension().lastPathComponent, size: 15, serif: true)
        column.children.append(name)
        let pick = Pressable(radius: 12) { [weak self] in self?.open(url) }
        pick.hoverWash = 0
        pick.box.pointerEntered.addHandler { _, _ in name.foreground = Theme.brush(Theme.pencil) }
        pick.box.pointerExited.addHandler { _, _ in name.foreground = Theme.ink(1) }
        pick.box.child = column
        // What a right click on a design offers, as on the Mac.
        let box = pick.box
        box.rightTapped.addHandler { [weak self] _, args in
            args?.handled = true
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menus.show(below: box, width: 220, entries: self.designEntries(url, rename: { self.rename(url, label: name, column: column) }))
                }
            }
        }
        return box
    }

    private func designEntries(_ url: URL, rename: @escaping @MainActor () -> Void) -> [MenuHost.Entry] {
        [
            .item(Words.t("Open")) { [weak self] in self?.open(url) },
            .item(Words.t("Show in Explorer")) {
                let explorer = Process()
                explorer.executableURL = URL(fileURLWithPath: "C:\\Windows\\explorer.exe")
                explorer.arguments = ["/select," + url.path.replacingOccurrences(of: "/", with: "\\")]
                try? explorer.run()
            },
            .item(Words.t("Rename")) { rename() },
            .item(Words.t("Duplicate")) { [weak self] in
                let folder = url.deletingLastPathComponent(), base = url.deletingPathExtension().lastPathComponent + " copy"
                var copy = folder.appendingPathComponent("\(base).bezzle")
                var i = 2
                while FileManager.default.fileExists(atPath: copy.path) {
                    copy = folder.appendingPathComponent("\(base) \(i).bezzle")
                    i += 1
                }
                guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { MessageBeep(0); return }
                self?.refresh()
            },
            .separator,
            .item(Words.t("Move to Recycle Bin")) { [weak self] in
                guard WindowsCore.recycle(url) else { MessageBeep(0); return }
                self?.refresh()
            },
        ]
    }

    /// The design's name typed anew in its place: Enter keeps it, Esc puts it back.
    private func rename(_ url: URL, label: TextBlock, column: StackPanel) {
        var k: UInt32 = 0
        guard (try? column.children.indexOf(label, &k)) == true else { return }
        let field = TextBox()
        field.text = label.text
        field.fontFamily = Theme.serif
        field.fontSize = 15
        field.minHeight = 0
        field.padding = Theme.inset(4, 2, 4, 2)
        column.children.removeAt(k)
        column.children.insertAt(k, field)
        var done = false
        func finish(_ keep: Bool) {
            guard !done else { return }
            done = true
            let typed = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let clean = String(typed.map { "\\/:*?\"<>|".contains($0) ? "-" : $0 })
            let target = url.deletingLastPathComponent().appendingPathComponent("\(clean).bezzle")
            if keep, !clean.isEmpty, clean != label.text, !FileManager.default.fileExists(atPath: target.path),
               (try? FileManager.default.moveItem(at: url, to: target)) != nil {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh() } }
                return
            }
            if keep, !clean.isEmpty, clean != label.text { MessageBeep(0) }
            var at: UInt32 = 0
            if (try? column.children.indexOf(field, &at)) == true {
                column.children.removeAt(at)
                column.children.insertAt(at, label)
            }
        }
        field.keyDown.addHandler { _, args in
            guard let args else { return }
            if args.key == .enter { args.handled = true; finish(true) }
            if args.key == .escape { args.handled = true; finish(false) }
        }
        field.lostFocus.addHandler { _, _ in finish(true) }
        field.loaded.addHandler { sender, _ in
            guard let box = sender as? TextBox else { return }
            _ = try? box.focus(.programmatic)
            try? box.selectAll()
        }
    }

    /// The designs listed again, as they are in the folder now.
    func refresh() {
        shownWidth = 0
        showDesigns()
    }
}
