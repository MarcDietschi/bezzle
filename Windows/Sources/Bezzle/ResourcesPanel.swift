import Foundation
import WinUI
import UWP
import WindowsFoundation
import WinSDK
import BezzleCore

/// Ready-made parts and icons in the layers list's place, as the Mac's Views/ResourcesPanel.swift:
/// a shelf of the design's own components, the kits and the icon sets, each opening as a page of
/// its own, as an artboard does in the layers list. Each part shows as itself, drawn as the canvas
/// draws it, in the light or dark of the artboard it would go onto. A click puts one onto that
/// artboard; dragging one carries the real thing onto the canvas, which shows how it will land.
@MainActor
final class ResourcesPanel {
    let root = Grid()
    private let session: DesignSession
    private let header = StackPanel()
    private let searchBox = TextBox()
    private let scroll = ScrollView()
    private let content = StackPanel()

    enum Page: Equatable { case kit(String), icons(String), library(URL) }
    private var page: Page?
    private var query = ""
    /// Whether the artboard parts would go onto is dark, so they show dark.
    private var dark = false
    /// How many icons the icon page shows so far: more come as it is scrolled to its foot.
    private var iconsShown = 0
    private var iconPageMore: (() -> Void)?

    /// Carrying a thing over the canvas: where the pointer is (nil when it is let go elsewhere).
    var carry: ((WindowsCore.Thing, PointerRoutedEventArgs?) -> Void)?
    /// Let go: whether over the canvas it was put there.
    var drop: ((WindowsCore.Thing, PointerRoutedEventArgs?) -> Void)?
    /// A click: the thing onto the artboard in view.
    var pick: ((WindowsCore.Thing) -> Void)?

    static let inner = 212.0
    static let gap = 8.0

    init(session: DesignSession) {
        self.session = session
        root.width = Theme.layersWidth
        for h in [GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star)] {
            let r = RowDefinition()
            r.height = h
            root.rowDefinitions.append(r)
        }
        header.orientation = .horizontal
        header.spacing = 7
        header.height = 20
        header.margin = Theme.inset(16, 8, 16, 8)
        root.children.append(header)

        let well = Theme.well(radius: 8)
        well.height = 28
        well.margin = Theme.inset(12, 0, 12, 10)
        let line = Grid()
        let c0 = ColumnDefinition(), c1 = ColumnDefinition()
        c0.width = GridLength(value: 1, gridUnitType: .auto)
        c1.width = GridLength(value: 1, gridUnitType: .star)
        line.columnDefinitions.append(c0)
        line.columnDefinitions.append(c1)
        let glass = Glyphs.view(Glyphs.magnifier(size: 12), size: 12, brush: Theme.ink(3))
        glass.margin = Theme.inset(9, 0, 4, 0)
        glass.verticalAlignment = .center
        line.children.append(glass)
        searchBox.placeholderText = Words.t("Search")
        searchBox.fontFamily = Theme.ui
        searchBox.fontSize = 12.5
        searchBox.background = Theme.clear
        searchBox.borderThickness = Theme.inset(0)
        searchBox.padding = Theme.inset(2, 5, 4, 2)
        searchBox.minHeight = 0
        searchBox.verticalAlignment = .center
        searchBox.textChanged.addHandler { [weak self] _, _ in
            guard let self else { return }
            let words = self.searchBox.text.trimmingCharacters(in: .whitespaces)
            guard words != self.query else { return }
            self.query = words
            self.show()
        }
        searchBox.keyDown.addHandler { [weak self] _, args in
            guard let self, let args, args.key == .escape else { return }
            args.handled = true
            self.searchBox.text = ""
        }
        try? Grid.setColumn(searchBox, 1)
        line.children.append(searchBox)
        well.child = line
        try? Grid.setRow(well, 1)
        root.children.append(well)

        content.margin = Theme.inset(12, 0, 12, 16)
        scroll.content = content
        scroll.viewChanged.addHandler { [weak self] _, _ in
            guard let self, let more = self.iconPageMore else { return }
            // Near the foot of the icons: the next of them.
            if self.scroll.verticalOffset > self.scroll.scrollableHeight - 300 { more() }
        }
        try? Grid.setRow(scroll, 2)
        root.children.append(scroll)

        session.listen { [weak self] in self?.shown() }
        shown()
    }

    /// Out or away, as the session says; drawn again when it comes out, or the artboard in view
    /// turns light or dark.
    private var wasOut = false
    private func shown() {
        let out = session.showsResources
        root.visibility = out ? .visible : .collapsed
        let darkNow = WindowsCore.isDarkBoard(session.board)
        if out, !wasOut || darkNow != dark {
            dark = darkNow
            show()
        }
        // Other designs, as libraries, as they were last saved.
        if out, !wasOut { readLibraries() }
        wasOut = out
    }

    /// The designs in the designs folder, newest first, as home shows them.
    static func designs() -> [URL] {
        let folder = BezzleApp.designsFolder
        func date(_ url: URL) -> Date? { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "bezzle" }
            .sorted { (date($0) ?? .distantPast) > (date($1) ?? .distantPast) }
    }

    /// Reads the other designs again where they changed, then shows what they hold.
    var libraryRead: (() -> Void)?
    func readLibraries() {
        WindowsCore.readLibraries(Self.designs()) { [weak self] in
            guard let self else { return }
            if self.session.showsResources, self.page == nil || { if case .library = self.page { return true }; return false }() { self.show() }
            self.libraryRead?()
        }
    }

    /// The design changed: its own components may have.
    func edited() {
        guard session.showsResources, page == nil else { return }
        show()
    }

    // MARK: Pages

    /// Runs once the event that asked for it is over: what it does may rebuild the panel, and the
    /// element the event is on with it, which WinUI does not survive mid-event.
    private func later(_ f: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { f() } }
    }

    private func open(_ target: Page?) {
        page = target
        _ = try? scroll.scrollTo(0, 0)
        show()
    }

    private func show() {
        drawHeader()
        content.children.clear()
        iconPageMore = nil
        switch page {
        case nil:
            if query.isEmpty { shelf() } else { found() }
        case .kit(let id):
            kitPage(id)
        case .icons(let id):
            iconPage(id)
        case .library(let url):
            libraryPage(url)
        }
    }

    private func drawHeader() {
        header.children.clear()
        let title = Theme.text(Words.t("Resources"), size: 13, weight: 600, ink: page == nil ? 1 : 3)
        title.isHitTestVisible = true
        if page != nil {
            let back = Border()
            back.background = Theme.clear
            back.child = title
            back.pointerEntered.addHandler { _, _ in title.foreground = Theme.ink(1) }
            back.pointerExited.addHandler { _, _ in title.foreground = Theme.ink(3) }
            back.tapped.addHandler { [weak self] _, _ in self?.later { self?.open(nil) } }
            header.children.append(back)
            let chevron = Glyphs.view(Glyphs.chevron(open: false, size: 9), size: 9, brush: Theme.ink(4))
            chevron.verticalAlignment = .center
            header.children.append(chevron)
            header.children.append(Theme.text(pageTitle, size: 13, weight: 600))
        } else {
            header.children.append(title)
        }
    }

    private var pageTitle: String {
        switch page {
        case .kit(let id): return WindowsCore.kits().first { $0.id == id }.map { Words.t($0.title) } ?? id
        case .icons(let id): return WindowsCore.iconSets().first { $0.id == id }?.name ?? id
        case .library(let url): return url.deletingPathExtension().lastPathComponent
        case nil: return ""
        }
    }

    private func hairline() -> UIElement {
        let line = Border()
        line.height = 0.5
        line.background = Theme.hairline
        line.margin = Theme.inset(0, 14, 0, 14)
        return line
    }

    /// Two to a row, `width` each.
    private func pairs(_ items: [FrameworkElement], spacing: Double = 12) -> UIElement {
        let grid = Grid()
        for _ in 0..<2 {
            let c = ColumnDefinition()
            c.width = GridLength(value: (Self.inner - Self.gap) / 2, gridUnitType: .pixel)
            grid.columnDefinitions.append(c)
        }
        grid.columnSpacing = Self.gap
        grid.rowSpacing = spacing
        for _ in 0..<((items.count + 1) / 2) {
            let r = RowDefinition()
            r.height = GridLength(value: 1, gridUnitType: .auto)
            grid.rowDefinitions.append(r)
        }
        for (i, item) in items.enumerated() {
            try? Grid.setColumn(item, Int32(i % 2))
            try? Grid.setRow(item, Int32(i / 2))
            grid.children.append(item)
        }
        return grid
    }

    // MARK: The shelf

    private func shelf() {
        // The design's own components first: what it is made of, to use again.
        let own = WindowsCore.ownComponents()
        if !own.isEmpty {
            content.children.append(pairs(own.map { ownTile($0.id, name: $0.name, copies: $0.copies) }))
            content.children.append(hairline())
        }
        // The other designs with components or styles of their own, to take from.
        let libraries = WindowsCore.libraries()
        if !libraries.isEmpty {
            content.children.append(pairs(libraries.map { lib in
                let c = card(lib.name, count: lib.components + lib.styles, coverHeight: 76, cover: libraryCover(lib.url)) { [weak self] in self?.open(.library(lib.url)) }
                guard lib.news else { return c }
                // What was taken from it changed there since: a dot at its corner.
                let holder = Grid()
                holder.children.append(c)
                let dot = Ellipse()
                dot.width = 10
                dot.height = 10
                dot.fill = Theme.brush(Theme.linked)
                dot.stroke = Theme.brush(Theme.paper)
                dot.strokeThickness = 1.5
                dot.horizontalAlignment = .right
                dot.verticalAlignment = .top
                dot.margin = Theme.inset(0, -3, -3, 0)
                holder.children.append(dot)
                return holder
            }))
            content.children.append(hairline())
        }
        content.children.append(pairs(WindowsCore.kits().map { kit in
            card(Words.t(kit.title), count: kit.count, coverHeight: 76, cover: kitCover(kit)) { [weak self] in self?.open(.kit(kit.id)) }
        }))
        content.children.append(hairline())
        let sets = StackPanel()
        sets.spacing = 12
        for set in WindowsCore.iconSets() {
            sets.children.append(card(set.name, count: set.count, coverHeight: 44, cover: iconCover(set)) { [weak self] in self?.open(.icons(set.id)) })
        }
        content.children.append(sets)
    }

    /// A library on the shelf: a picture of what is in it, its name and how much it holds.
    private func card(_ title: String, count: Int?, coverHeight: Double, cover: FrameworkElement, action: @escaping @MainActor () -> Void) -> FrameworkElement {
        let stack = StackPanel()
        stack.spacing = 6
        let frame = Border()
        frame.height = coverHeight
        frame.cornerRadius = Theme.corners(10)
        frame.borderBrush = Theme.hairline
        frame.borderThickness = Theme.inset(1)
        frame.child = cover
        let lift = CompositeTransform()
        frame.renderTransform = lift
        frame.renderTransformOrigin = Point(x: 0.5, y: 0.5)
        stack.children.append(frame)
        let line = Grid()
        let c0 = ColumnDefinition(), c1 = ColumnDefinition()
        c0.width = GridLength(value: 1, gridUnitType: .star)
        c1.width = GridLength(value: 1, gridUnitType: .auto)
        line.columnDefinitions.append(c0)
        line.columnDefinitions.append(c1)
        line.margin = Theme.inset(2, 0, 2, 0)
        line.children.append(Theme.text(title, size: 12, weight: 500))
        if let count {
            let n = Theme.text("\(count)", size: 11, ink: 3)
            try? Grid.setColumn(n, 1)
            line.children.append(n)
        }
        stack.children.append(line)
        let hit = Border()
        hit.background = Theme.clear
        hit.child = stack
        hit.pointerEntered.addHandler { _, _ in lift.scaleX = 1.03; lift.scaleY = 1.03 }
        hit.pointerExited.addHandler { _, _ in lift.scaleX = 1; lift.scaleY = 1 }
        hit.tapped.addHandler { [weak self] _, _ in self?.later(action) }
        return hit
    }

    private func picture(_ size: CGSize, _ draw: (_ scale: Double, _ fill: (Int, Int) -> UnsafeMutableRawPointer?) -> Bool) -> Image {
        Inspector.rendered(size, draw)
    }

    private func kitCover(_ kit: WindowsCore.KitLook) -> FrameworkElement {
        let holder = Grid()
        holder.background = Theme.brush(dark ? kit.darkPaper : kit.paper)
        var drawn: CGSize?
        var bitmap: WriteableBitmap?
        drawn = WindowsCore.kitCover(kit.id, dark: dark, scale: 2) { w, h in
            bitmap = WriteableBitmap(Int32(w), Int32(h))
            return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        if let drawn, let bitmap {
            try? bitmap.invalidate()
            let image = Image()
            image.source = bitmap
            image.stretch = .uniform
            image.margin = Theme.inset(8)
            image.maxWidth = Double(drawn.width)
            image.maxHeight = Double(drawn.height)
            holder.children.append(image)
        }
        return holder
    }

    private static let samples: [String: [String]] = [
        "lucide": ["heart", "bell", "camera", "house", "search", "settings", "send"],
        "phosphor": ["heart", "bell", "camera", "house", "magnifying-glass", "gear", "paper-plane-tilt"],
        "material": ["favorite", "notifications", "photo_camera", "home", "search", "settings", "send"],
    ]

    private func iconCover(_ set: WindowsCore.IconSetLook) -> FrameworkElement {
        let holder = Grid()
        holder.background = Theme.brush(Theme.card)
        let row = Grid()
        row.margin = Theme.inset(8, 0, 8, 0)
        let names = (Self.samples[set.id] ?? []).filter { WindowsCore.hasIcon(set.id, $0) }
        for (i, name) in names.enumerated() {
            let c = ColumnDefinition()
            c.width = GridLength(value: 1, gridUnitType: .star)
            row.columnDefinitions.append(c)
            let g = iconGlyph(set, name, style: set.defaultStyle, weight: set.defaultWeight, size: 18, brush: Theme.ink(1))
            g.horizontalAlignment = .center
            g.verticalAlignment = .center
            try? Grid.setColumn(g, Int32(i))
            row.children.append(g)
        }
        holder.children.append(row)
        return holder
    }

    // MARK: Tiles

    /// One of the design's components, drawn as a new copy of it would look.
    private func ownTile(_ id: UUID, name: String, copies: Int) -> FrameworkElement {
        let width = (Self.inner - Self.gap) / 2
        let face = Grid()
        face.background = Theme.brush(Theme.card)
        let image = picture(CGSize(width: width - 12, height: 64)) { scale, fill in
            WindowsCore.ownPicture(id, size: CGSize(width: width - 12, height: 64), scale: scale, into: fill)
        }
        image.horizontalAlignment = .center
        image.verticalAlignment = .center
        face.children.append(image)
        let caption = StackPanel()
        caption.orientation = .horizontal
        caption.spacing = 4
        let mark = Glyphs.view(Glyphs.component(size: 9), size: 9, brush: Theme.brush(Theme.linked))
        mark.verticalAlignment = .center
        caption.children.append(mark)
        let words = Theme.text(name, size: 11, ink: 2)
        words.maxWidth = width - 40
        caption.children.append(words)
        caption.children.append(Theme.text("\(copies)", size: 11, ink: 3))
        let tile = tileFrame(face, width: width, height: 76, caption: caption, ring: Theme.linked, thing: .own(id))
        try? ToolTipService.setToolTip(tile, Words.t("%lld copies in this design", copies))
        return tile
    }

    /// One part, drawn as it would come out, on its kit's paper, with its name under it.
    private func partTile(_ part: WindowsCore.PartLook, width: Double, showsKit: Bool) -> FrameworkElement {
        let paper = WindowsCore.kits().first { $0.id == part.kit }.map { dark ? $0.darkPaper : $0.paper } ?? 0xFFFFFF
        var height = 72.0
        if width >= Self.inner, let sheet = WindowsCore.partSheet(part.id) {
            let k = min(1, (width - 12) / Double(sheet.width))
            height = min(max(Double(sheet.height) * k + 12, 44), 150).rounded()
        }
        let face = Grid()
        face.background = Theme.brush(paper)
        var bitmap: WriteableBitmap?
        let sheet = WindowsCore.partPicture(part.id, dark: dark, scale: 2) { w, h in
            bitmap = WriteableBitmap(Int32(w), Int32(h))
            return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        if let sheet, let bitmap {
            try? bitmap.invalidate()
            let k = min(1, (width - 12) / Double(sheet.width), (height - 12) / Double(sheet.height))
            let image = Image()
            image.source = bitmap
            image.stretch = .fill
            image.width = Double(sheet.width) * k
            image.height = Double(sheet.height) * k
            image.horizontalAlignment = .center
            image.verticalAlignment = .center
            face.children.append(image)
        }
        let caption = StackPanel()
        caption.orientation = .horizontal
        caption.spacing = 4
        let words = Theme.text(Words.t(part.title), size: 11, ink: 2)
        words.maxWidth = width - 4
        caption.children.append(words)
        if showsKit { caption.children.append(Theme.text(Words.t(part.kitTitle), size: 11, ink: 3)) }
        return tileFrame(face, width: width, height: height, caption: caption, ring: Theme.pencil, thing: .part(part.id))
    }

    /// A tile: its face in a rounded frame that lifts under the pointer, its caption under it; a
    /// click puts its thing onto the artboard in view, a drag carries it onto the canvas.
    private func tileFrame(_ face: FrameworkElement, width: Double, height: Double, caption: FrameworkElement,
                           ring: UInt32, thing: WindowsCore.Thing) -> FrameworkElement {
        let stack = StackPanel()
        stack.spacing = 5
        stack.width = width
        let frame = Border()
        frame.width = width
        frame.height = height
        frame.cornerRadius = Theme.corners(9)
        frame.borderBrush = Theme.hairline
        frame.borderThickness = Theme.inset(1)
        frame.child = face
        let lift = CompositeTransform()
        frame.renderTransform = lift
        frame.renderTransformOrigin = Point(x: 0.5, y: 0.5)
        stack.children.append(frame)
        caption.margin = Theme.inset(2, 0, 2, 0)
        stack.children.append(caption)
        let hit = Border()
        hit.background = Theme.clear
        hit.child = stack
        carrying(hit, thing: thing) { hovering, pressed in
            frame.borderBrush = hovering ? Theme.brush(ring, 0.5) : Theme.hairline
            let k = pressed ? 0.97 : hovering ? 1.02 : 1
            lift.scaleX = k
            lift.scaleY = k
        }
        return hit
    }

    /// Presses on `element` pick its thing, or carry it onto the canvas once they move.
    private func carrying(_ element: FrameworkElement, thing: WindowsCore.Thing, look: @escaping @MainActor (_ hovering: Bool, _ pressed: Bool) -> Void) {
        var down: Point?
        var carried = false
        var hovering = false
        element.pointerEntered.addHandler { _, _ in hovering = true; look(true, down != nil) }
        element.pointerExited.addHandler { _, _ in hovering = false; if down == nil { look(false, false) } }
        element.pointerPressed.addHandler { _, args in
            guard let args, let p = try? args.getCurrentPoint(nil) else { return }
            args.handled = true
            down = p.position
            carried = false
            _ = try? element.capturePointer(args.pointer)
            look(true, true)
        }
        element.pointerMoved.addHandler { [weak self] _, args in
            guard let self, let start = down, let args, let p = try? args.getCurrentPoint(nil) else { return }
            if !carried, hypot(Double(p.position.x - start.x), Double(p.position.y - start.y)) > 3 {
                carried = true
                look(hovering, false)
            }
            if carried { self.carry?(thing, args) }
        }
        element.pointerReleased.addHandler { [weak self] _, args in
            guard let self, down != nil else { return }
            down = nil
            try? element.releasePointerCaptures()
            look(hovering, false)
            if carried {
                carried = false
                // Where it was let go, read now, while the event is live; done once it is over.
                self.drop?(thing, args)
            } else {
                self.later { self.pick?(thing) }
            }
        }
        element.pointerCaptureLost.addHandler { [weak self] _, _ in
            guard let self, down != nil else { return }
            down = nil
            if carried { carried = false; self.drop?(thing, nil) }
            look(false, false)
        }
    }

    // MARK: A kit

    private func kitPage(_ id: String) {
        let sections = WindowsCore.kitSections(id, query: query)
        for s in sections {
            let title = Theme.text(Words.t(s.title), size: 11.5, weight: 600, ink: 3)
            title.margin = Theme.inset(0, 6, 0, 8)
            content.children.append(title)
            let rows = partRows(s.parts, showsKit: false)
            rows.margin = Theme.inset(0, 0, 0, 10)
            content.children.append(rows)
        }
        if sections.isEmpty { content.children.append(nothingFound()) }
    }

    /// Parts laid in rows: a wide one alone, small ones two by two.
    private func partRows(_ parts: [WindowsCore.PartLook], showsKit: Bool) -> FrameworkElement {
        let stack = StackPanel()
        stack.spacing = 12
        var waiting: WindowsCore.PartLook?
        func row(_ items: [WindowsCore.PartLook]) {
            let line = StackPanel()
            line.orientation = .horizontal
            line.spacing = Self.gap
            for p in items {
                let wide = items.count == 1 && p.wide
                line.children.append(partTile(p, width: wide ? Self.inner : (Self.inner - Self.gap) / 2, showsKit: showsKit))
            }
            stack.children.append(line)
        }
        for p in parts {
            if p.wide {
                if let w = waiting { row([w]); waiting = nil }
                row([p])
            } else if let w = waiting {
                row([w, p])
                waiting = nil
            } else {
                waiting = p
            }
        }
        if let w = waiting { row([w]) }
        return stack
    }

    // MARK: Icons

    /// The style last picked for a set, kept as the Mac keeps it: "lucide=0:2;phosphor=4:2".
    private func style(for set: WindowsCore.IconSetLook) -> (index: Int, weight: Double) {
        let saved = UserDefaults.standard.string(forKey: "resources.iconStyles") ?? ""
        for entry in saved.split(separator: ";") {
            let parts = entry.split(separator: "=")
            guard parts.count == 2, parts[0] == set.id else { continue }
            let v = parts[1].split(separator: ":")
            if v.count == 2, let i = Int(v[0]), let w = Double(v[1]), set.styles.indices.contains(i) { return (i, w) }
        }
        return (set.defaultStyle, set.defaultWeight)
    }

    private func save(_ style: (index: Int, weight: Double), for set: WindowsCore.IconSetLook) {
        let saved = UserDefaults.standard.string(forKey: "resources.iconStyles") ?? ""
        var entries = saved.split(separator: ";").map(String.init).filter { !$0.hasPrefix(set.id + "=") }
        entries.append("\(set.id)=\(style.index):\(style.weight)")
        UserDefaults.standard.set(entries.joined(separator: ";"), forKey: "resources.iconStyles")
    }

    /// One of Bezzle's words by the Mac's key, with its English for a key Words has not.
    private func keyed(_ key: String, _ english: String) -> String {
        let t = Words.t(key)
        return t == key ? english : t
    }

    private func iconPage(_ id: String) {
        guard let set = WindowsCore.iconSets().first(where: { $0.id == id }) else { return }
        let picked = style(for: set)
        content.children.append(styleStrip(set, picked))
        let names = WindowsCore.icons(id, query: query)
        let grid = iconGrid()
        content.children.append(grid.root)
        iconsShown = 0
        // A hundred and eighty at a time, as a lazy grid would.
        let more: @MainActor () -> Void = { [weak self] in
            guard let self, self.iconsShown < names.count else { return }
            let next = names[self.iconsShown..<min(self.iconsShown + 180, names.count)]
            for icon in next { grid.add(self.iconCell(set, icon.name, words: icon.words, style: picked)) }
            self.iconsShown += next.count
        }
        more()
        iconPageMore = more
        if names.isEmpty { content.children.append(nothingFound()) }
    }

    /// One icon drawn in each style the set has, or at each weight for a set of lines: the one
    /// picked sits in a well.
    private func styleStrip(_ set: WindowsCore.IconSetLook, _ picked: (index: Int, weight: Double)) -> FrameworkElement {
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 4
        row.margin = Theme.inset(0, 0, 0, 10)
        var choices: [(index: Int, weight: Double, title: String)] = []
        if set.lines {
            for (w, key, english) in [(1.0, "icon.thin", "Thin"), (1.5, "icon.light", "Light"), (2.0, "icon.regular", "Regular"),
                                      (2.5, "icon.bold", "Bold"), (3.0, "icon.heavy", "Heavy")] {
                choices.append((0, w, keyed(key, english)))
            }
        } else {
            let names = ["thin": ("icon.thin", "Thin"), "light": ("icon.light", "Light"), "regular": ("icon.regular", "Regular"),
                         "bold": ("icon.bold", "Bold"), "fill": ("icon.filled", "Filled"), "outline": ("icon.outlined", "Outlined")]
            for (i, name) in set.styles.enumerated() {
                choices.append((i, picked.weight, names[name].map { keyed($0.0, $0.1) } ?? name))
            }
        }
        let sample = WindowsCore.hasIcon(set.id, "star") ? "star" : WindowsCore.icons(set.id, query: "").first?.name ?? ""
        for c in choices {
            let on = set.lines ? abs(c.weight - picked.weight) < 0.01 : c.index == picked.index
            let cell = on ? Theme.well(radius: 8) : Border()
            cell.width = 36
            cell.height = 30
            cell.cornerRadius = Theme.corners(8)
            if !on { cell.background = Theme.clear }
            let g = iconGlyph(set, sample, style: c.index, weight: c.weight, size: 18, brush: Theme.ink(on ? 1 : 2))
            g.horizontalAlignment = .center
            g.verticalAlignment = .center
            cell.child = g
            cell.pointerEntered.addHandler { _, _ in if !on { cell.background = Theme.brush(Theme.ink, 0.06) } }
            cell.pointerExited.addHandler { _, _ in if !on { cell.background = Theme.clear } }
            cell.tapped.addHandler { [weak self] _, _ in
                self?.later {
                    self?.save((c.index, c.weight), for: set)
                    self?.show()
                }
            }
            try? ToolTipService.setToolTip(cell, c.title)
            row.children.append(cell)
        }
        return row
    }

    private static let cell = 32.0

    /// Icons six to a row.
    private func iconGrid() -> IconRows { IconRows(spacing: (Self.inner - Self.cell * 6) / 5) }

    private func iconCell(_ set: WindowsCore.IconSetLook, _ name: String, words: String, style: (index: Int, weight: Double)) -> FrameworkElement {
        let cell = Border()
        cell.width = Self.cell
        cell.height = Self.cell
        cell.cornerRadius = Theme.corners(8)
        cell.background = Theme.clear
        cell.horizontalAlignment = .left
        let g = iconGlyph(set, name, style: style.index, weight: style.weight, size: 20, brush: Theme.brush(Theme.ink, 0.82))
        g.horizontalAlignment = .center
        g.verticalAlignment = .center
        cell.child = g
        let lift = CompositeTransform()
        cell.renderTransform = lift
        cell.renderTransformOrigin = Point(x: 0.5, y: 0.5)
        try? ToolTipService.setToolTip(cell, words)
        carrying(cell, thing: .icon(set: set.id, name: name, style: style.index, weight: style.weight)) { hovering, pressed in
            cell.background = hovering ? Theme.brush(Theme.pencil, Theme.pencilWash) : Theme.clear
            let k = pressed ? 0.9 : hovering ? 1.08 : 1
            lift.scaleX = k
            lift.scaleY = k
        }
        return cell
    }

    /// An icon drawn as it will come in: a set of lines stroked at its weight, round at the ends
    /// and corners, others filled.
    private func iconGlyph(_ set: WindowsCore.IconSetLook, _ name: String, style: Int, weight: Double, size: Double, brush: Brush) -> FrameworkElement {
        let holder = Canvas()
        holder.width = size + 4
        holder.height = size + 4
        holder.isHitTestVisible = false
        let data = WindowsCore.iconData(set.id, name, style: style)
        guard !data.isEmpty else { return holder }
        let k = size / max(Double(set.box.width), 1)
        let xaml = set.lines
            ? "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(data)' StrokeThickness='\(weight)' StrokeStartLineCap='Round' StrokeEndLineCap='Round' StrokeLineJoin='Round'/>"
            : "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(data)'/>"
        guard let path = (try? XamlReader.load(xaml)) as? WinUI.Path else { return holder }
        if set.lines { path.stroke = brush } else { path.fill = brush }
        let t = CompositeTransform()
        t.scaleX = k
        t.scaleY = k
        t.translateX = 2 - Double(set.box.minX) * k
        t.translateY = 2 - Double(set.box.minY) * k
        path.renderTransform = t
        holder.children.append(path)
        return holder
    }

    // MARK: Another design

    /// Another design on the shelf: a few of its components, and its colours along the foot.
    private func libraryCover(_ url: URL) -> FrameworkElement {
        let holder = Grid()
        holder.background = Theme.brush(Theme.card)
        let masters = WindowsCore.libraryCoverComponents(url)
        let colours = WindowsCore.libraryColours(url)
        let r0 = RowDefinition(), r1 = RowDefinition()
        r0.height = GridLength(value: 1, gridUnitType: .star)
        r1.height = GridLength(value: 1, gridUnitType: .auto)
        holder.rowDefinitions.append(r0)
        holder.rowDefinitions.append(r1)
        if !masters.isEmpty {
            let row = StackPanel()
            row.orientation = .horizontal
            row.spacing = 6
            row.horizontalAlignment = .center
            row.verticalAlignment = .center
            for id in masters {
                row.children.append(picture(CGSize(width: 46, height: 34)) { scale, fill in
                    WindowsCore.libraryPicture(url, master: id, size: CGSize(width: 46, height: 34), scale: scale, into: fill)
                })
            }
            holder.children.append(row)
        }
        if !colours.isEmpty {
            let strip = Grid()
            strip.height = masters.isEmpty ? 76 : 14
            for (i, c) in colours.enumerated() {
                let col = ColumnDefinition()
                col.width = GridLength(value: 1, gridUnitType: .star)
                strip.columnDefinitions.append(col)
                let swatch = Rectangle()
                swatch.fill = Theme.brush(c.colour, c.alpha)
                try? Grid.setColumn(swatch, Int32(i))
                strip.children.append(swatch)
            }
            try? Grid.setRow(strip, masters.isEmpty ? 0 : 1)
            if masters.isEmpty { try? Grid.setRowSpan(strip, 2) }
            holder.children.append(strip)
        }
        return holder
    }

    /// Another design's styles and components, to take into this one: its styles first, as small
    /// chips, a click giving one to the selection (or, with nothing selected, to the design); then
    /// its components, a click or a drag putting a copy onto the canvas.
    private func libraryPage(_ url: URL) {
        let styles = WindowsCore.libraryStyles(url, query: query)
        let masters = WindowsCore.libraryComponents(url, query: query)
        if let news = WindowsCore.news().first(where: { $0.url.standardizedFileURL.path.lowercased() == url.standardizedFileURL.path.lowercased() }) {
            content.children.append(newsRow(news))
        }
        if !styles.isEmpty {
            let chips = pairs(styles.map { styleChip($0, of: url) }, spacing: 6)
            (chips as? FrameworkElement)?.margin = Theme.inset(0, 0, 0, 14)
            content.children.append(chips)
        }
        if !masters.isEmpty { content.children.append(libraryComponents(url, masters)) }
        if styles.isEmpty && masters.isEmpty { content.children.append(nothingFound()) }
    }

    private func libraryComponents(_ url: URL, _ masters: [(id: UUID, name: String, taken: Bool)]) -> UIElement {
        let width = (Self.inner - Self.gap) / 2
        return pairs(masters.map { m in
            let face = Grid()
            face.background = Theme.brush(Theme.card)
            let image = picture(CGSize(width: width - 12, height: 64)) { scale, fill in
                WindowsCore.libraryPicture(url, master: m.id, size: CGSize(width: width - 12, height: 64), scale: scale, into: fill)
            }
            image.horizontalAlignment = .center
            image.verticalAlignment = .center
            face.children.append(image)
            let caption = StackPanel()
            caption.orientation = .horizontal
            caption.spacing = 4
            // Taken already, it is this design's own too, and marked so.
            if m.taken {
                let mark = Glyphs.view(Glyphs.component(size: 9), size: 9, brush: Theme.brush(Theme.linked))
                mark.verticalAlignment = .center
                caption.children.append(mark)
            }
            let words = Theme.text(m.name, size: 11, ink: 2)
            words.maxWidth = width - 20
            caption.children.append(words)
            return tileFrame(face, width: width, height: 76, caption: caption, ring: Theme.linked, thing: .library(url, m.id))
        })
    }

    /// One style of another design. Pointing at it shows it on the selection; a click gives it to
    /// the selection, bringing it into this design, or with nothing selected only brings it in.
    private func styleChip(_ style: WindowsCore.LibraryStyleLook, of url: URL) -> FrameworkElement {
        let row = Grid()
        row.height = 32
        row.cornerRadius = Theme.corners(8)
        row.background = Theme.clear
        row.padding = Theme.inset(5, 0, 5, 0)
        for w in [GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star), GridLength(value: 1, gridUnitType: .auto)] {
            let c = ColumnDefinition()
            c.width = w
            row.columnDefinitions.append(c)
        }
        row.columnSpacing = 7
        let pic = stylePicture(style, size: 22)
        pic.verticalAlignment = .center
        row.children.append(pic)
        let words = Theme.text(style.name, size: 11, ink: 2)
        try? Grid.setColumn(words, 1)
        row.children.append(words)
        if style.taken {
            let dot = Ellipse()
            dot.width = 4
            dot.height = 4
            dot.fill = Theme.brush(Theme.pencil)
            dot.verticalAlignment = .center
            try? Grid.setColumn(dot, 2)
            row.children.append(dot)
        }
        let session = session
        row.pointerEntered.addHandler { _, _ in
            row.background = Theme.brush(Theme.ink, 0.05)
            words.foreground = Theme.ink(1)
            WindowsCore.previewStyle(style.id, of: url, on: session.selection)
            session.previewed(board: nil)
        }
        row.pointerExited.addHandler { _, _ in
            row.background = Theme.clear
            words.foreground = Theme.ink(2)
            WindowsCore.previewStyle(nil, of: url, on: [])
            session.previewed(board: nil)
        }
        row.tapped.addHandler { [weak self] _, _ in
            self?.later {
                WindowsCore.previewStyle(nil, of: url, on: [])
                WindowsCore.useStyle(style.id, of: url, on: session.selection)
                session.edited(board: nil)
                self?.show()
            }
        }
        try? ToolTipService.setToolTip(row, style.name)
        return row
    }

    /// What a style looks like, small: a colour as a chip, type in itself, a shadow under a card,
    /// corners as one corner drawn.
    private func stylePicture(_ style: WindowsCore.LibraryStyleLook, size: Double) -> FrameworkElement {
        switch style.kind {
        case "colour":
            let chip = Border()
            chip.width = size
            chip.height = size
            chip.cornerRadius = Theme.corners(size * 0.3)
            chip.borderBrush = Theme.hairline
            chip.borderThickness = Theme.inset(0.5)
            if style.gradient.count > 1 {
                let brush = LinearGradientBrush()
                brush.startPoint = Point(x: 0, y: 0)
                brush.endPoint = Point(x: 1, y: 1)
                for (i, c) in style.gradient.enumerated() {
                    let stop = GradientStop()
                    stop.color = Theme.color(c)
                    stop.offset = Double(i) / Double(style.gradient.count - 1)
                    brush.gradientStops.append(stop)
                }
                chip.background = brush
            } else {
                chip.background = Theme.brush(style.colour, style.alpha)
            }
            return chip
        case "text":
            let well = Theme.well(radius: size * 0.3)
            well.width = size
            well.height = size
            let aa = Theme.text("Aa", size: size * 0.5, weight: 500)
            aa.horizontalAlignment = .center
            well.child = aa
            return well
        case "shadow":
            let holder = Grid()
            holder.width = size
            holder.height = size
            if let s = style.shadow {
                let under = Border()
                under.width = size * 0.7
                under.height = size * 0.58
                under.cornerRadius = Theme.corners(4)
                under.background = Theme.brush(s.colour, min(1, s.alpha * 3))
                under.horizontalAlignment = .center
                under.verticalAlignment = .center
                under.margin = Theme.inset(max(s.x / 4, 0), min(max(s.y / 4, 1), 3) + 1, 0, 0)
                holder.children.append(under)
            }
            let card = Border()
            card.width = size * 0.7
            card.height = size * 0.58
            card.cornerRadius = Theme.corners(4)
            card.background = Theme.brush(0xFFFFFF)
            card.horizontalAlignment = .center
            card.verticalAlignment = .center
            holder.children.append(card)
            return holder
        default:
            let holder = Canvas()
            holder.width = size
            holder.height = size
            let r = min(style.radius / 2, size * 0.5)
            var p = PathData()
            let x0 = size * 0.27, y0 = size * 0.27, w = size * 0.7
            p.move(x0, y0 + w)
            p.line(x0, y0 + r)
            if r > 0 { p.quad(x0, y0, x0 + r, y0) }
            p.line(x0 + w, y0)
            let g = Glyphs.view([Glyphs.Part(data: p.d, mode: .stroke, width: 1.6)], size: size, brush: Theme.ink(1))
            holder.children.append(g)
            return holder
        }
    }

    /// What changed in this library since the design took from it, on its page: the same offer as
    /// on the canvas, for when that was set aside.
    private func newsRow(_ news: WindowsCore.NewsLook) -> FrameworkElement {
        let row = Grid()
        row.cornerRadius = Theme.corners(10)
        row.background = Theme.brush(Theme.linked, 0.08)
        row.padding = Theme.inset(10, 4, 4, 4)
        row.margin = Theme.inset(0, 0, 0, 14)
        let c0 = ColumnDefinition(), c1 = ColumnDefinition()
        c0.width = GridLength(value: 1, gridUnitType: .star)
        c1.width = GridLength(value: 1, gridUnitType: .auto)
        row.columnDefinitions.append(c0)
        row.columnDefinitions.append(c1)
        row.columnSpacing = 8
        let words = Theme.text(news.words, size: 11.5, ink: 2)
        words.textWrapping = .wrap
        words.maxLines = 2
        row.children.append(words)
        let update = LibraryNewsChip.updateButton(news.url, session: session) { [weak self] in self?.show() }
        try? Grid.setColumn(update, 1)
        row.children.append(update)
        return row
    }

    // MARK: Found

    private func found() {
        // The components of other designs called so, first: the user's own.
        var anyTheirs = false
        for lib in WindowsCore.libraries() {
            let found = WindowsCore.libraryComponents(lib.url, query: query)
            guard !found.isEmpty else { continue }
            anyTheirs = true
            let title = Theme.text(lib.name, size: 11.5, weight: 600, ink: 3)
            title.margin = Theme.inset(0, 0, 0, 8)
            content.children.append(title)
            let tiles = libraryComponents(lib.url, found)
            (tiles as? FrameworkElement)?.margin = Theme.inset(0, 0, 0, 14)
            content.children.append(tiles)
        }
        let parts = WindowsCore.foundParts(query)
        if !parts.isEmpty {
            let rows = partRows(parts, showsKit: true)
            rows.margin = Theme.inset(0, 0, 0, 14)
            content.children.append(rows)
        }
        var any = !parts.isEmpty || anyTheirs
        for set in WindowsCore.iconSets() {
            let names = WindowsCore.icons(set.id, query: query)
            guard !names.isEmpty else { continue }
            any = true
            let line = Grid()
            let c0 = ColumnDefinition(), c1 = ColumnDefinition()
            c0.width = GridLength(value: 1, gridUnitType: .star)
            c1.width = GridLength(value: 1, gridUnitType: .auto)
            line.columnDefinitions.append(c0)
            line.columnDefinitions.append(c1)
            line.margin = Theme.inset(0, 0, 0, 6)
            line.children.append(Theme.text(set.name, size: 11.5, weight: 600, ink: 3))
            if names.count > 18 {
                let more = Border()
                more.cornerRadius = Theme.corners(8)
                more.padding = Theme.inset(6, 1, 6, 1)
                more.background = Theme.brush(Theme.ink, 0.05)
                more.child = Theme.text("\(names.count)", size: 11, ink: 3)
                more.pointerEntered.addHandler { _, _ in more.background = Theme.brush(Theme.pencil, Theme.pencilWash) }
                more.pointerExited.addHandler { _, _ in more.background = Theme.brush(Theme.ink, 0.05) }
                more.tapped.addHandler { [weak self] _, _ in self?.later { self?.open(.icons(set.id)) } }
                try? Grid.setColumn(more, 1)
                line.children.append(more)
            }
            content.children.append(line)
            let grid = iconGrid()
            grid.root.margin = Theme.inset(0, 0, 0, 14)
            let picked = style(for: set)
            for icon in names.prefix(18) { grid.add(iconCell(set, icon.name, words: icon.words, style: picked)) }
            content.children.append(grid.root)
        }
        if !any { content.children.append(nothingFound()) }
    }

    /// Nothing fits what was typed: a faint circle with a question in it.
    private func nothingFound() -> FrameworkElement {
        let holder = Grid()
        holder.margin = Theme.inset(0, 28, 0, 28)
        let ring = Ellipse()
        ring.width = 22
        ring.height = 22
        ring.stroke = Theme.ink(4)
        ring.strokeThickness = 1.2
        ring.horizontalAlignment = .center
        holder.children.append(ring)
        let q = Theme.text("?", size: 13, weight: 300, ink: 4)
        q.horizontalAlignment = .center
        q.verticalAlignment = .center
        holder.children.append(q)
        return holder
    }
}

/// Icons laid six to a row, a row at a time as they come.
@MainActor
final class IconRows {
    let root = StackPanel()
    private var row: StackPanel?
    private var inRow = 0
    private let across: Double

    init(spacing: Double) {
        across = spacing
        root.spacing = 4
    }

    func add(_ cell: FrameworkElement) {
        if row == nil || inRow >= 6 {
            let next = StackPanel()
            next.orientation = .horizontal
            next.spacing = across
            root.children.append(next)
            row = next
            inRow = 0
        }
        row?.children.append(cell)
        inRow += 1
    }
}
