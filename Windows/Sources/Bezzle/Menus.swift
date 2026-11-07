import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// Bezzle's own menus, as the Mac's MenuHost draws them (Views/Menus.swift), never the system's:
/// a card of radius 12, lifted, 6 inside, its rows 28 tall with a column for a check, the title
/// (13, ink; ink at 22% when it cannot be chosen) and its shortcut at the right (12, ink3),
/// washed with ink at 7% under the pointer, radius 7; hairlines between groups, 4 above and
/// below. It opens at the pointer, below it or above when there is no room, 12 from the edges.
/// A press anywhere else, or Esc, closes it.
@MainActor
final class MenuHost {
    struct Entry {
        var title = ""
        var shortcut: String?
        var enabled = true
        var checked = false
        var action: (@MainActor () -> Void)?
        var separator = false
        /// Pointing at it shows it on the canvas (true), and leaving takes that away (false).
        var preview: (@MainActor (Bool) -> Void)?
        /// Its title in a font of its own, as the fonts menu shows each family.
        var font: FontFamily?
        /// A line that says something, not to be chosen.
        var note = false
        /// A second line under the title, quieter (11, ink3): a size's numbers, say. The row is
        /// 40 tall then.
        var detail: String?

        static func item(_ title: String, detail: String? = nil, shortcut: String? = nil, enabled: Bool = true, checked: Bool = false,
                         font: FontFamily? = nil, preview: (@MainActor (Bool) -> Void)? = nil,
                         _ action: @escaping @MainActor () -> Void) -> Entry {
            Entry(title: title, shortcut: shortcut, enabled: enabled, checked: checked, action: action, preview: preview, font: font, detail: detail)
        }
        static let separator = Entry(separator: true)
        static func note(_ text: String) -> Entry { Entry(title: text, enabled: false, note: true) }
    }

    /// Over the whole window: the menu, and what closes it when pressed.
    let layer = Canvas()
    private let catcher = Border()
    private var card: Border?
    private var shade: Image?
    /// What to do once it closes, however it closes: take a preview away, say.
    private var closed: (() -> Void)?
    var isOpen: Bool { card != nil }

    init() {
        layer.isHitTestVisible = false
        catcher.background = Theme.clear
        catcher.visibility = .collapsed
        catcher.pointerPressed.addHandler { [weak self] _, args in
            args?.handled = true
            self?.close()
        }
        layer.children.append(catcher)
        layer.sizeChanged.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.catcher.width = self.layer.actualWidth
            self.catcher.height = self.layer.actualHeight
        }
    }

    /// Something that takes its own presses while a menu is open, such as a gradient's handles
    /// on the canvas: over what catches presses round the menu, under the menus themselves.
    func addOverCatcher(_ element: UIElement) {
        try? layer.children.insertAt(1, element)
    }

    /// Opens a menu below `anchor` (or above it, where there is no room), as wide as `width`
        /// or the anchor, its left edge in line with the anchor's: the Mac's MenuButton menus.
    func show(below anchor: FrameworkElement, width: Double? = nil, entries: [Entry], searchable: Bool = false, closed: (() -> Void)? = nil) {
        guard let t = try? anchor.transformToVisual(layer), let p = try? t.transformPoint(Point(x: 0, y: 0)) else { return }
        let w = max(width ?? 0, anchor.actualWidth)
        show(at: CGPoint(x: Double(p.x), y: Double(p.y) + anchor.actualHeight + 2), width: w, entries: entries,
             above: Double(p.y) - 2, reveal: entries.firstIndex(where: \.checked), searchable: searchable, closed: closed)
    }

    /// Opens a menu at `point` in the window: below it, or ending at `above` (the point itself
    /// unless given) when there is no room. Taller than the window, it scrolls, to `reveal` first.
    /// Searchable (the fonts menu), typing narrows it to the entries whose titles hold what was
    /// typed, in a field at its top, as on the Mac; Enter takes the first of them.
    func show(at point: CGPoint, width: Double = 220, entries: [Entry], above: Double? = nil, reveal: Int? = nil,
              searchable: Bool = false, closed: (() -> Void)? = nil) {
        close()
        guard !entries.isEmpty else { return }
        self.closed = closed
        // As wide as its widest entry needs, words and shortcut, as the Mac's menus are: the
        // words are longer in German than in English.
        let width = max(width, min(440, Self.fit(entries)))
        let card = Theme.card(radius: 12)
        card.width = width
        let list = StackPanel()
        list.padding = Theme.inset(6)
        var (height, revealAt) = fill(list, entries, width: width, reveal: reveal)
        let field = TextBox()
        if searchable {
            field.placeholderText = Words.t("Search")
            field.fontFamily = Theme.ui
            field.fontSize = 12.5
            field.minHeight = 0
            field.padding = Theme.inset(10, 5, 10, 0)
            field.margin = Theme.inset(6, 6, 6, 0)
            field.height = 28
            height += 34
        }
        // Below the pointer when it fits there or there is more room below than above, as the Mac's.
        let room = (w: layer.actualWidth, h: layer.actualHeight), gap = 2.0
        let top = above ?? Double(point.y)
        let roomBelow = room.h - 12 - Double(point.y) - gap, roomAbove = top - gap - 12
        let below = height <= roomBelow || roomBelow >= roomAbove
        let shown = min(height, below ? roomBelow : roomAbove)
        let body: UIElement
        if shown < height || searchable {
            let scroll = ScrollView()
            scroll.content = list
            scroll.height = shown - (searchable ? 34 : 0)
            body = scroll
            if revealAt > 0 {
                let to = max(0, min(revealAt - shown / 2 + 14, height - shown))
                scroll.loaded.addHandler { _, _ in _ = try? scroll.scrollTo(0, to) }
            }
        } else {
            body = list
        }
        if searchable {
            let stack = StackPanel()
            stack.children.append(field)
            stack.children.append(body)
            card.child = stack
            var matching = entries
            field.textChanged.addHandler { [weak self] _, _ in
                guard let self else { return }
                let words = field.text.trimmingCharacters(in: .whitespaces)
                matching = words.isEmpty ? entries : entries.filter { !$0.separator && !$0.note && Words.t($0.title).localizedCaseInsensitiveContains(words) }
                list.children.clear()
                _ = self.fill(list, matching, width: width, reveal: nil)
            }
            field.keyDown.addHandler { [weak self] _, args in
                guard let self, let args else { return }
                if args.key == .escape { args.handled = true; self.close() }
                if args.key == .enter, let first = matching.first(where: { !$0.separator && !$0.note && $0.enabled }) {
                    args.handled = true
                    self.close()
                    first.action?()
                }
            }
            field.loaded.addHandler { sender, _ in _ = try? (sender as? TextBox)?.focus(.programmatic) }
        } else {
            card.child = body
        }
        let y = below ? Double(point.y) + gap : top - gap - shown
        present(card, x: Double(point.x), y: y, width: width, height: shown)
    }

    /// The entries' rows into `list`: how tall they are, and where the one to `reveal` begins.
    private func fill(_ list: StackPanel, _ entries: [Entry], width: Double, reveal: Int?) -> (height: Double, revealAt: Double) {
        var height = 12.0, revealAt = 0.0
        for (k, entry) in entries.enumerated() {
            if k == reveal { revealAt = height - 6 }
            if entry.separator {
                let line = Border()
                line.height = 0.5
                line.background = Theme.hairline
                line.margin = Theme.inset(8, 4, 8, 4)
                list.children.append(line)
                height += 8.5
            } else if entry.note {
                let words = Theme.text(Words.t(entry.title), size: 12, ink: 3)
                words.textWrapping = .wrap
                words.margin = Theme.inset(8, 6, 8, 6)
                words.width = width - 28
                list.children.append(words)
                height += 34
            } else {
                list.children.append(row(entry, width: width - 12))
                height += entry.detail == nil ? 28 : 40
            }
        }
        return (height, revealAt)
    }

    /// A panel of Bezzle's own hanging from `anchor` (below it, or above it where there is no
    /// room), its left edge in line with the anchor's: the Mac's colour panel and fill menu.
    /// `content` is `width` by `height`.
    func panel(below anchor: FrameworkElement, width: Double, height: Double, content: UIElement, closed: (() -> Void)? = nil) {
        guard let t = try? anchor.transformToVisual(layer), let p = try? t.transformPoint(Point(x: 0, y: 0)) else { return }
        close()
        self.closed = closed
        let at = (x: Double(p.x), below: Double(p.y) + anchor.actualHeight + 2, above: Double(p.y) - 2)
        place(panel: content, width: width, height: height, x: at.x, below: at.below, above: at.above)
        panelAt = at
    }

    /// The panel open made again with other content, of another height, where it hangs: the
    /// inspector's cards are made again as the design changes, its anchor with them.
    func replace(panel content: UIElement, width: Double, height: Double) {
        guard let at = panelAt, isOpen else { return }
        let then = closed
        closed = nil
        close()
        closed = then
        place(panel: content, width: width, height: height, x: at.x, below: at.below, above: at.above)
        panelAt = at
    }

    /// Where the open panel hangs from.
    private var panelAt: (x: Double, below: Double, above: Double)?

    private func place(panel content: UIElement, width: Double, height: Double, x: Double, below: Double, above: Double) {
        let card = Theme.card(radius: 12)
        card.width = width
        card.height = height
        card.child = content
        let room = layer.actualHeight
        let fits = below + height <= room - 12 || room - below >= above
        present(card, x: x, y: fits ? below : max(12, above - height), width: width, height: height)
    }

    /// Puts a card up at `x`, `y` (kept 12 from the window's sides), lifted on its shadow, and
    /// catches presses round it.
    private func present(_ card: Border, x: Double, y: Double, width: Double, height shown: Double) {
        let room = (w: layer.actualWidth, h: layer.actualHeight)
        let x = min(max(x, 12), room.w - width - 12)
        try? Canvas.setLeft(card, x)
        try? Canvas.setTop(card, y)
        // Lifted, as the Mac's card is: a soft shadow under it, drawn as the artboards' are.
        let scale = layer.xamlRoot?.rasterizationScale ?? 1
        var bitmap: WriteableBitmap?, pad = 0
        _ = WindowsCore.artboardShadow(width: Int((width * scale).rounded()), height: Int((shown * scale).rounded()), scale: scale, colour: Theme.shadow) { w, h, p in
            pad = p
            bitmap = WriteableBitmap(Int32(w), Int32(h))
            return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        if let bitmap {
            try? bitmap.invalidate()
            let image = Image()
            image.source = bitmap
            image.isHitTestVisible = false
            image.width = width + 2 * Double(pad) / scale
            image.height = shown + 2 * Double(pad) / scale
            try? Canvas.setLeft(image, x - Double(pad) / scale)
            try? Canvas.setTop(image, y - Double(pad) / scale + 3)
            layer.children.append(image)
            self.shade = image
        }
        layer.children.append(card)
        self.card = card
        catcher.width = room.w
        catcher.height = room.h
        catcher.visibility = .visible
        layer.isHitTestVisible = true
    }

    func close() {
        guard let open = card else { return }
        card = nil
        panelAt = nil
        for element in [open, shade].compactMap({ $0 }) as [UIElement] {
            var k: UInt32 = 0
            if (try? layer.children.indexOf(element, &k)) == true { layer.children.removeAt(k) }
        }
        shade = nil
        catcher.visibility = .collapsed
        layer.isHitTestVisible = false
        let then = closed
        closed = nil
        then?()
    }

    /// How wide a menu of these entries has to be for none to be cut short: a row's margins, the
    /// tick's column, its words, its shortcut, and the card's padding.
    private static func fit(_ entries: [Entry]) -> Double {
        var widest = 0.0
        for entry in entries where !entry.separator && !entry.note {
            let title = Theme.text(Words.t(entry.title), size: 13)
            if let font = entry.font { title.fontFamily = font }
            try? title.measure(Size(width: 1000, height: 40))
            var w = 8 + 12 + 8 + Double(title.desiredSize.width) + 8
            if let shortcut = entry.shortcut {
                let keys = Theme.text(shortcut, size: 12)
                try? keys.measure(Size(width: 400, height: 40))
                w += 8 + Double(keys.desiredSize.width)
            }
            widest = max(widest, w)
        }
        return widest + 12 + 4
    }

    private func row(_ entry: Entry, width: Double) -> UIElement {
        let press = Pressable(radius: 7) { [weak self] in
            self?.close()
            entry.action?()
        }
        press.hoverWash = entry.enabled ? 0.07 : 0
        press.box.height = entry.detail == nil ? 28 : 40
        press.box.width = width
        press.box.isHitTestVisible = entry.enabled
        if let preview = entry.preview {
            press.box.pointerEntered.addHandler { _, _ in preview(true) }
            press.box.pointerExited.addHandler { _, _ in preview(false) }
        }
        let grid = Grid()
        grid.margin = Theme.inset(8, 0, 8, 0)
        for w in [GridLength(value: 12, gridUnitType: .pixel), GridLength(value: 1, gridUnitType: .star), GridLength(value: 1, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = w
            grid.columnDefinitions.append(column)
        }
        if entry.checked {
            let check = Glyphs.view(Glyphs.check(size: 10), size: 10, brush: Theme.ink(1))
            check.verticalAlignment = .center
            grid.children.append(check)
        }
        let title = Theme.text(Words.t(entry.title), size: 13, ink: entry.enabled ? 1 : 4)
        if let font = entry.font { title.fontFamily = font }
        title.verticalAlignment = .center
        title.textTrimming = .characterEllipsis
        if let detail = entry.detail {
            let lines = StackPanel()
            lines.spacing = 2
            lines.verticalAlignment = .center
            lines.margin = Theme.inset(8, 0, 0, 0)
            lines.children.append(title)
            let more = Theme.text(Words.t(detail), size: 11, ink: entry.enabled ? 3 : 4)
            more.textTrimming = .characterEllipsis
            lines.children.append(more)
            try? Grid.setColumn(lines, 1)
            grid.children.append(lines)
        } else {
            title.margin = Theme.inset(8, 0, 0, 0)
            try? Grid.setColumn(title, 1)
            grid.children.append(title)
        }
        if let shortcut = entry.shortcut {
            let keys = Theme.text(shortcut, size: 12, ink: entry.enabled ? 3 : 4)
            keys.verticalAlignment = .center
            keys.margin = Theme.inset(8, 0, 0, 0)
            try? Grid.setColumn(keys, 2)
            grid.children.append(keys)
        }
        press.box.child = grid
        return press.box
    }
}
