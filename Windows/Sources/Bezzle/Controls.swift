import Foundation
import WinUI
import UWP
import BezzleCore

/// The inspector's small controls, as the Mac draws them (Views/Controls.swift, Inspector.swift,
/// Presets.swift): a button that opens a menu, a choice of a few symbols in a well, symbols each
/// on or off, and a strip of presets. What they do runs once the tap is over (as `Pressable`),
/// since it often makes the panel again, these controls with it.
@MainActor
enum Controls {
    static let height = 28.0

    private static func later(_ f: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { f() } }
    }

    /// The Mac's MenuButton: its value and a chevron at the far end, in a wash of ink (4%, 6.5%
    /// under the pointer, 9% while its menu is open), radius 8, 28 tall; the menu opens under it.
    static func menuButton(_ title: String, width: Double? = nil, font: FontFamily? = nil, menus: MenuHost?, menuWidth: Double? = nil,
                           entries: @escaping @MainActor () -> [MenuHost.Entry], closed: (() -> Void)? = nil) -> FrameworkElement {
        let box = Border()
        box.height = height
        if let width { box.width = width }
        box.cornerRadius = Theme.corners(8)
        let rest = Theme.brush(Theme.ink, 0.04), hover = Theme.brush(Theme.ink, 0.065), open = Theme.brush(Theme.ink, 0.09)
        box.background = rest
        let grid = Grid()
        for w in [GridLength(value: 1, gridUnitType: .star), GridLength(value: 1, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = w
            grid.columnDefinitions.append(column)
        }
        let words = Theme.text(title, size: 12.5)
        if let font { words.fontFamily = font }
        words.verticalAlignment = .center
        words.textTrimming = .characterEllipsis
        words.margin = Theme.inset(10, 0, 4, 0)
        grid.children.append(words)
        let chevron = Glyphs.view(Glyphs.chevron(), size: 9, brush: Theme.ink(3))
        chevron.verticalAlignment = .center
        chevron.margin = Theme.inset(0, 0, 8, 0)
        try? Grid.setColumn(chevron, 1)
        grid.children.append(chevron)
        box.child = grid
        var isOpen = false
        box.pointerEntered.addHandler { _, _ in if !isOpen { box.background = hover } }
        box.pointerExited.addHandler { _, _ in if !isOpen { box.background = rest } }
        box.pointerPressed.addHandler { _, args in args?.handled = true }
        box.tapped.addHandler { _, args in
            args?.handled = true
            later {
                guard let menus else { return }
                isOpen = true
                box.background = open
                menus.show(below: box, width: menuWidth, entries: entries()) {
                    isOpen = false
                    box.background = rest
                    closed?()
                }
            }
        }
        return box
    }

    /// A well of radius 8, 2 inside, holding cells side by side, each as wide as the others.
    private static func well(_ cells: [FrameworkElement], width: Double?) -> FrameworkElement {
        let well = Theme.well(radius: 8)
        if let width { well.width = width }
        let grid = Grid()
        grid.margin = Theme.inset(2)
        for (k, cell) in cells.enumerated() {
            let column = ColumnDefinition()
            column.width = GridLength(value: 1, gridUnitType: .star)
            grid.columnDefinitions.append(column)
            try? Grid.setColumn(cell, Int32(k))
            grid.children.append(cell)
        }
        well.child = grid
        return well
    }

    /// One cell of a well, 24 tall: raised on a card (radius 6) when chosen or on, else washed
    /// with ink at 5% under the pointer.
    private static func cell(_ content: FrameworkElement, raised: Bool, hoverWash: Bool = true, pointed: ((Bool) -> Void)? = nil,
                             _ press: @escaping @MainActor () -> Void) -> FrameworkElement {
        let box = Border()
        box.height = height - 4
        box.cornerRadius = Theme.corners(6)
        box.background = raised ? Theme.brush(Theme.card) : Theme.clear
        if raised {
            box.borderBrush = Theme.brush(Theme.shadow, 0.1)
            box.borderThickness = Theme.inset(0, 0, 0, 0.75)
        }
        content.horizontalAlignment = .center
        content.verticalAlignment = .center
        box.child = content
        box.pointerEntered.addHandler { _, _ in
            if !raised, hoverWash { box.background = Theme.brush(Theme.ink, 0.05) }
            pointed?(true)
        }
        box.pointerExited.addHandler { _, _ in
            if !raised { box.background = Theme.clear }
            pointed?(false)
        }
        box.pointerPressed.addHandler { _, args in args?.handled = true }
        box.tapped.addHandler { _, args in
            args?.handled = true
            later(press)
        }
        return box
    }

    private static func symbol(_ glyph: [Glyphs.Part], on: Bool) -> FrameworkElement {
        Glyphs.view(glyph, size: 14, brush: on ? Theme.ink(1) : Theme.ink(2))
    }

    /// The Mac's IconChoice: one of a few, each a symbol; the one chosen raised.
    static func iconChoice<Value: Equatable>(_ selection: Value?, _ options: [(Value, [Glyphs.Part])], width: Double? = nil,
                                             choose: @escaping @MainActor (Value) -> Void) -> FrameworkElement {
        well(options.map { value, glyph in
            let on = value == selection
            return cell(symbol(glyph, on: on), raised: on) { choose(value) }
        }, width: width)
    }

    /// The Mac's GlyphChoice: one of a few, each a picture told whether it is the one chosen.
    static func glyphChoice<Value: Equatable>(_ selection: Value?, _ options: [Value], width: Double? = nil,
                                              glyph: (Value, Bool) -> FrameworkElement,
                                              choose: @escaping @MainActor (Value) -> Void) -> FrameworkElement {
        well(options.map { value in
            let on = value == selection
            return cell(glyph(value, on), raised: on) { choose(value) }
        }, width: width)
    }

    /// The Mac's CardButton: a word or two on a card, radius 0.28 of its height, half its
    /// height either side; lifted under the pointer.
    static func cardButton(_ title: String, height h: Double = 32, _ action: @escaping @MainActor () -> Void) -> FrameworkElement {
        let card = Theme.card(radius: h * 0.28)
        card.height = h
        card.horizontalAlignment = .left
        let label = Theme.text(title, size: h >= 32 ? 13 : 12.5, weight: 500)
        label.margin = Theme.inset(h / 2, 0, h / 2, 0)
        label.verticalAlignment = .center
        card.child = label
        let rest = card.borderBrush
        card.pointerEntered.addHandler { _, _ in card.borderBrush = Theme.brush(Theme.shadow, 0.2) }
        card.pointerExited.addHandler { _, _ in card.borderBrush = rest }
        card.pointerPressed.addHandler { _, args in args?.handled = true }
        card.tapped.addHandler { _, args in
            args?.handled = true
            later(action)
        }
        return card
    }

    /// The Mac's Switch: a capsule 32 by 18, ink when on with its knob at the right, a well when
    /// off with its knob at the left.
    static func toggle(_ on: Bool, _ set: @escaping @MainActor (Bool) -> Void) -> FrameworkElement {
        let grid = Grid()
        grid.width = 32
        grid.height = 18
        grid.horizontalAlignment = .left
        let track = Border()
        track.cornerRadius = Theme.corners(9)
        track.background = on ? Theme.brush(Theme.ink) : Theme.brush(Theme.well)
        if !on {
            // The well's shade inside its top edge.
            track.borderBrush = Theme.brush(Theme.shadow, 0.22)
            track.borderThickness = Theme.inset(0, 1, 0, 0)
        }
        grid.children.append(track)
        let knob = Border()
        knob.width = 14
        knob.height = 14
        knob.cornerRadius = Theme.corners(7)
        knob.background = Theme.brush(on ? Theme.onInk : Theme.card)
        knob.borderBrush = Theme.brush(Theme.shadow, 0.2)
        knob.borderThickness = Theme.inset(0, 0, 0, 0.75)
        knob.horizontalAlignment = on ? .right : .left
        knob.verticalAlignment = .center
        knob.margin = Theme.inset(2, 0, 2, 0)
        grid.children.append(knob)
        grid.background = Theme.clear
        grid.pointerPressed.addHandler { _, args in args?.handled = true }
        grid.tapped.addHandler { _, args in
            args?.handled = true
            later { set(!on) }
        }
        return grid
    }

    /// The Mac's IconToggles: a few symbols, each on or off by itself, such as underline and
    /// strikethrough.
    static func iconToggles(_ options: [([Glyphs.Part], Bool, @MainActor () -> Void)], width: Double? = nil) -> FrameworkElement {
        well(options.map { glyph, on, press in cell(symbol(glyph, on: on), raised: on, press) }, width: width)
    }

    /// The Mac's PresetStrip: choices drawn small, the one in use raised. Pointing at one shows
    /// it on the canvas straight away (`point`), a click makes it.
    static func presetStrip(_ items: [(content: FrameworkElement, active: Bool)], width: Double? = nil,
                            point: @escaping @MainActor (Int?) -> Void, choose: @escaping @MainActor (Int) -> Void) -> FrameworkElement {
        well(items.enumerated().map { k, item in
            cell(item.content, raised: item.active, pointed: { on in if !item.active { point(on ? k : nil) } }) {
                point(nil)
                choose(k)
            }
        }, width: width)
    }

    /// The Mac's SegmentedWell: a few words in a well of radius 9, the one chosen on a card
    /// (radius 7) that slides along it; each word given room by how long it is, so they look evenly set.
    static func segmented<Value: Equatable>(_ selection: Value?, _ options: [(Value, String)], width: Double? = nil,
                                            choose: @escaping @MainActor (Value) -> Void) -> FrameworkElement {
        let well = Theme.well(radius: 9)
        if let width { well.width = width }
        let grid = Grid()
        grid.margin = Theme.inset(2)
        for (k, (value, word)) in options.enumerated() {
            let column = ColumnDefinition()
            column.width = GridLength(value: Double(word.count) + 6, gridUnitType: .star)
            grid.columnDefinitions.append(column)
            let on = value == selection
            let label = Theme.text(Words.t(word), size: 12, weight: on ? 500 : 400, ink: on ? 1 : 2)
            let box = Border()
            box.height = height - 4
            box.cornerRadius = Theme.corners(7)
            box.background = on ? Theme.brush(Theme.card) : Theme.clear
            if on {
                box.borderBrush = Theme.brush(Theme.shadow, 0.1)
                box.borderThickness = Theme.inset(0, 0, 0, 0.75)
            }
            label.horizontalAlignment = .center
            label.verticalAlignment = .center
            box.child = label
            box.pointerPressed.addHandler { _, args in args?.handled = true }
            box.tapped.addHandler { _, args in
                args?.handled = true
                if !on { later { choose(value) } }
            }
            try? Grid.setColumn(box, Int32(k))
            grid.children.append(box)
        }
        well.child = grid
        return well
    }

    /// A line or two that says how something works, under its controls (the Mac's Caption).
    static func caption(_ words: String) -> FrameworkElement {
        let text = Theme.text(Words.t(words), size: 11, ink: 3)
        text.textWrapping = .wrap
        text.lineHeight = 16
        return text
    }

    /// The Mac's EntryField: a word or two in a well, kept on Enter or leaving, Esc putting back
    /// what was there; `commit` says how what was typed reads now, or nil to put it back.
    static func entry(_ text: String, placeholder: String = "", width: Double? = nil, enabled: Bool = true,
                      commit: @escaping @MainActor (String) -> String?) -> FrameworkElement {
        let well = Theme.well(radius: 7)
        well.height = height
        if let width { well.width = width }
        well.opacity = enabled ? 1 : 0.4
        well.isHitTestVisible = enabled
        let box = TextBox()
        box.allowFocusOnInteraction = true
        box.text = text
        box.placeholderText = Words.t(placeholder)
        box.fontFamily = Theme.ui
        box.fontSize = 12
        box.textWrapping = .wrap
        box.minWidth = 0
        box.minHeight = 0
        box.padding = Theme.inset(8, 5, 6, 0)
        box.verticalAlignment = .center
        box.borderThickness = Theme.inset(0)
        box.background = Theme.clear
        for key in ["TextControlBackground", "TextControlBackgroundPointerOver", "TextControlBackgroundFocused",
                    "TextControlBorderBrush", "TextControlBorderBrushPointerOver", "TextControlBorderBrushFocused"] {
            _ = box.resources?.insert(key, Theme.clear)
        }
        for key in ["TextControlForeground", "TextControlForegroundPointerOver", "TextControlForegroundFocused"] {
            _ = box.resources?.insert(key, Theme.ink(1))
        }
        well.child = box
        var shown = text
        func take() {
            let typed = box.text.trimmingCharacters(in: .whitespaces)
            guard typed != shown else { return }
            let now = commit(typed) ?? shown
            shown = now
            box.text = now
        }
        box.pointerPressed.addHandler { _, args in args?.handled = true }
        box.keyDown.addHandler { _, args in
            guard let args else { return }
            if args.key == .enter { args.handled = true; take() }
            if args.key == .escape { args.handled = true; box.text = shown }
        }
        box.lostFocus.addHandler { _, _ in take() }
        return well
    }

    /// A symbol button, `size` square, washed under the pointer (the Mac's IconButton).
    static func iconButton(_ glyph: [Glyphs.Part], size: Double = 24, _ action: @escaping @MainActor () -> Void) -> FrameworkElement {
        let press = Pressable(radius: 6, action: action)
        press.box.width = size
        press.box.height = size
        let view = Glyphs.view(glyph, size: 14, brush: Theme.ink(2))
        view.horizontalAlignment = .center
        view.verticalAlignment = .center
        press.box.child = view
        return press.box
    }

    /// The Mac's Row: a title in the first column, its control where the second column starts.
    static func row(_ title: String, _ control: FrameworkElement) -> FrameworkElement {
        let grid = Grid()
        grid.minHeight = height
        for w in [GridLength(value: Inspector.column + Inspector.columnGap, gridUnitType: .pixel), GridLength(value: 1, gridUnitType: .star)] {
            let column = ColumnDefinition()
            column.width = w
            grid.columnDefinitions.append(column)
        }
        let words = Theme.text(Words.t(title), size: 12, ink: 2)
        words.verticalAlignment = .center
        words.textTrimming = .characterEllipsis
        grid.children.append(words)
        // A control of no width of its own fills the rest of the row, as a menu button does.
        control.horizontalAlignment = control.width.isNaN ? .stretch : .left
        try? Grid.setColumn(control, 1)
        grid.children.append(control)
        return grid
    }

    /// Side by side, `spacing` apart, the last taking what room is left.
    static func line(_ items: [FrameworkElement], spacing: Double = 8) -> FrameworkElement {
        let grid = Grid()
        grid.columnSpacing = spacing
        for (k, item) in items.enumerated() {
            let column = ColumnDefinition()
            // A control with a width of its own keeps it; the others share what is left.
            column.width = item.width.isNaN ? GridLength(value: 1, gridUnitType: .star) : GridLength(value: 1, gridUnitType: .auto)
            grid.columnDefinitions.append(column)
            try? Grid.setColumn(item, Int32(k))
            grid.children.append(item)
        }
        return grid
    }
}
