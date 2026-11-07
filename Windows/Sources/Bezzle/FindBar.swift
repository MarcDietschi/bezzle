import Foundation
import WinUI
import UWP
import WindowsFoundation
import WinSDK
import BezzleCore

/// Looking through the design's words, laid over the top of the canvas, as the Mac's FindBar:
/// what to find and what to put in its place, or, turned to spelling, each misspelt word in turn
/// and how it might be spelt. What it finds is lit on the canvas (`DesignCanvas.drawFound`), and
/// Enter goes on to the next, Shift+Enter back.
@MainActor
final class FindBar {
    let root = Grid()
    private let session: DesignSession
    private let card = Theme.card(radius: 14)
    private let shadow = Image()
    private let findBox = TextBox()
    private let replaceBox = TextBox()
    private lazy var findWell = Self.well(findBox)
    private lazy var replaceWell = Self.well(replaceBox)
    private let choiceSlot = Border()
    private let middleSlot = Border()
    private let count = Theme.text("", size: 11, ink: 3)
    private let optionsSlot = Border()
    private let buttons = StackPanel()
    private let replacedLine = Theme.text("", size: 11, ink: 3)
    private let secondRow = Grid()
    /// The second row's first column: the options' room, none while spelling.
    private let optionsColumn = ColumnDefinition()
    /// How many the last All replaced, said under the bar until something else is done.
    private var replaced: Int?
    /// The misspelt word last offered a spelling for.
    private var offeredFor: String?
    /// Filling the fields from the finder, not typing.
    private var filling = false
    /// Which way the bar is laid out: for spelling or not. Its fields are moved only when that
    /// changes, as moving one takes the keys from it.
    private var laidForSpelling: Bool?

    var menus: MenuHost?
    /// What is found or picked out changed: the canvas marks it again.
    var changed: (() -> Void)?
    /// Gives the keys back to the canvas, once the bar is closed.
    var returnFocus: (() -> Void)?

    init(session: DesignSession) {
        self.session = session
        root.horizontalAlignment = .center
        root.verticalAlignment = .top
        root.margin = Theme.inset(0, 14, 0, 0)
        root.width = 420
        root.visibility = .collapsed
        shadow.isHitTestVisible = false
        shadow.stretch = .fill
        root.children.append(shadow)
        root.children.append(card)
        root.sizeChanged.addHandler { [weak self] _, _ in self?.drawShadow() }
        card.pointerPressed.addHandler { _, args in args?.handled = true }

        let stack = StackPanel()
        stack.spacing = 6
        stack.padding = Theme.inset(8)
        card.child = stack

        // What to find, or the misspelt word; how many; previous, next and close.
        let first = Grid()
        first.columnSpacing = 6
        for w in [GridLength(value: 60, gridUnitType: .pixel), GridLength(value: 1, gridUnitType: .star)] + Array(repeating: GridLength(value: 1, gridUnitType: .auto), count: 4) {
            let column = ColumnDefinition()
            column.width = w
            first.columnDefinitions.append(column)
        }
        first.children.append(choiceSlot)
        try? Grid.setColumn(middleSlot, 1)
        first.children.append(middleSlot)
        count.verticalAlignment = .center
        try? Grid.setColumn(count, 2)
        first.children.append(count)
        let previous = Controls.iconButton(Glyphs.chevron(up: true, size: 12)) { [weak self] in self?.next(forward: false) }
        try? ToolTipService.setToolTip(previous, Words.t("Previous  Shift+Enter"))
        let next = Controls.iconButton(Glyphs.chevron(size: 12)) { [weak self] in self?.next(forward: true) }
        try? ToolTipService.setToolTip(next, Words.t("Next  Enter"))
        let close = Controls.iconButton(Glyphs.cross(size: 20)) { [weak self] in self?.close() }
        try? ToolTipService.setToolTip(close, Words.t("Close") + "  Esc")
        for (k, b) in [previous, next, close].enumerated() {
            try? Grid.setColumn(b, Int32(3 + k))
            first.children.append(b)
        }
        stack.children.append(first)

        // Match case and whole words, or nothing; the replacement; what to do with it.
        secondRow.columnSpacing = 6
        optionsColumn.width = GridLength(value: 60, gridUnitType: .pixel)
        secondRow.columnDefinitions.append(optionsColumn)
        for w in [GridLength(value: 1, gridUnitType: .star), GridLength(value: 1, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = w
            secondRow.columnDefinitions.append(column)
        }
        secondRow.children.append(optionsSlot)
        try? Grid.setColumn(replaceWell, 1)
        secondRow.children.append(replaceWell)
        buttons.orientation = .horizontal
        buttons.spacing = 6
        try? Grid.setColumn(buttons, 2)
        secondRow.children.append(buttons)
        stack.children.append(secondRow)

        replacedLine.margin = Theme.inset(66, 0, 0, 0)
        replacedLine.visibility = .collapsed
        stack.children.append(replacedLine)

        findBox.placeholderText = Words.t("Find")
        findBox.textChanged.addHandler { [weak self] _, _ in
            guard let self, !self.filling, let finder = WindowsCore.finder else { return }
            finder.query = self.findBox.text
            self.replaced = nil
            self.refresh()
            self.changed?()
        }
        findBox.keyDown.addHandler { [weak self] _, args in
            guard let self, let args else { return }
            switch args.key {
            case .enter: args.handled = true; self.next(forward: GetKeyState(Int32(VK_SHIFT)) >= 0)
            case .escape: args.handled = true; self.close()
            default: break
            }
        }
        replaceBox.textChanged.addHandler { [weak self] _, _ in
            guard let self, !self.filling else { return }
            WindowsCore.finder?.replacement = self.replaceBox.text
        }
        replaceBox.keyDown.addHandler { [weak self] _, args in
            guard let self, let args else { return }
            switch args.key {
            case .enter: args.handled = true; self.replace()
            case .escape: args.handled = true; self.close()
            default: break
            }
        }
    }

    var isOpen: Bool { WindowsCore.finder != nil }

    // MARK: Opening and closing

    /// Opens the bar, or turns it to spelling, its field given the keys. Letters picked out
    /// while typing are what it looks for.
    func open(spelling: Bool = false, looking words: String? = nil) {
        let finder = WindowsCore.openFind(spelling: spelling)
        if !spelling, let words, !words.isEmpty { finder.query = words }
        replaced = nil
        offeredFor = nil
        root.visibility = .visible
        fill()
        if spelling { next(forward: true) } else { refresh() }
        changed?()
        let box = spelling ? replaceBox : findBox
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                _ = try? box.focus(.programmatic)
                if !spelling { try? box.selectAll() }
            }
        }
    }

    func close() {
        guard isOpen else { return }
        WindowsCore.closeFind()
        root.visibility = .collapsed
        changed?()
        returnFocus?()
    }

    /// The fields as the finder has them.
    private func fill() {
        guard let finder = WindowsCore.finder else { return }
        filling = true
        if findBox.text != finder.query { findBox.text = finder.query }
        if replaceBox.text != finder.replacement { replaceBox.text = finder.replacement }
        filling = false
    }

    // MARK: Doing

    /// Picks out the next thing found, or the one before, selecting its layer and bringing it
    /// into sight.
    func next(forward: Bool) {
        guard let finder = WindowsCore.finder else { return }
        show(finder.next(forward: forward, from: session.selection))
    }

    private func replace(with words: String? = nil) {
        guard let finder = WindowsCore.finder else { return }
        let picked = finder.replace(with: words, from: session.selection)
        session.edited(board: nil)
        show(picked)
    }

    private func replaceAll() {
        guard let finder = WindowsCore.finder else { return }
        let n = finder.replaceAll()
        if n > 0 { session.edited(board: nil) }
        replaced = n
        refresh()
        changed?()
    }

    private func show(_ id: UUID?) {
        if let id, session.selection != [id] { session.select([id], on: WindowsCore.board(of: id)) }
        if let id { session.reveal?(id) }
        refresh()
        changed?()
    }

    // MARK: Showing

    /// Everything on the bar as the finder is now: after an edit, say, or a choice.
    func refresh() {
        guard let finder = WindowsCore.finder else {
            root.visibility = .collapsed
            return
        }
        root.visibility = .visible
        let spelling = finder.spelling
        let n = finder.count
        choiceSlot.child = Controls.iconChoice(spelling, [(false, Glyphs.magnifier(size: 14)), (true, Glyphs.spelling())], width: 60) { [weak self] value in
            guard let self, let finder = WindowsCore.finder else { return }
            finder.spelling = value
            self.replaced = nil
            self.offeredFor = nil
            if value {
                self.next(forward: true)
                _ = try? self.replaceBox.focus(.programmatic)
            } else {
                self.filling = true
                self.replaceBox.text = ""
                self.filling = false
                finder.replacement = ""
                self.refresh()
                self.changed?()
                _ = try? self.findBox.focus(.programmatic)
            }
        }
        if let choice = choiceSlot.child {
            try? ToolTipService.setToolTip(choice, Words.t(spelling ? "Check spelling" : "Find and replace words"))
        }
        if spelling {
            middleSlot.child = misspelt(finder)
        } else if laidForSpelling != false {
            middleSlot.child = findWell
        }
        count.text = Self.counted(n, current: finder.current.flatMap { $0 < n ? $0 : nil }, spelling: spelling, query: finder.query)

        replaceBox.placeholderText = Words.t(spelling ? "Spell it as" : "Replace with")
        buttons.children.clear()
        if spelling {
            if laidForSpelling != true {
                optionsSlot.child = nil
                optionsColumn.width = GridLength(value: 0, gridUnitType: .pixel)
                secondRow.columnSpacing = 0
                try? Grid.setColumn(replaceWell, 0)
                try? Grid.setColumnSpan(replaceWell, 2)
            }
            // The word picked out offers its likeliest spelling to change it to.
            let word = finder.misspeltWord
            if word != offeredFor {
                offeredFor = word
                if let word {
                    let spelt = finder.guesses.first ?? word
                    filling = true
                    replaceBox.text = spelt
                    filling = false
                    finder.replacement = spelt
                }
            }
            let guesses = finder.guesses
            buttons.children.append(Controls.menuButton(Words.t("Spellings"), menus: menus, menuWidth: 200, entries: { [weak self] in
                guesses.isEmpty ? [.note(Words.t("Windows has no spellings to offer for this word."))] : guesses.map { guess in
                    .item(guess, checked: guess == WindowsCore.finder?.replacement) { self?.replace(with: guess) }
                }
            }))
            buttons.children.append(Controls.cardButton(Words.t("Change"), height: 26) { [weak self] in self?.replace() })
            let ignore = Controls.cardButton(Words.t("Ignore"), height: 26) { [weak self] in
                guard let self, let finder = WindowsCore.finder else { return }
                self.show(finder.ignore(from: self.session.selection))
            }
            try? ToolTipService.setToolTip(ignore, Words.t("Leave this word as it is, everywhere in the design while it is open"))
            buttons.children.append(ignore)
            let learn = Controls.cardButton(Words.t("Learn"), height: 26) { [weak self] in
                guard let self, let finder = WindowsCore.finder else { return }
                self.show(finder.learn(from: self.session.selection))
            }
            try? ToolTipService.setToolTip(learn, Words.t("Add this word to the dictionary"))
            buttons.children.append(learn)
        } else {
            if laidForSpelling != false {
                optionsColumn.width = GridLength(value: 60, gridUnitType: .pixel)
                secondRow.columnSpacing = 6
                try? Grid.setColumn(replaceWell, 1)
                try? Grid.setColumnSpan(replaceWell, 1)
            }
            let toggles = Controls.iconToggles([
                (Glyphs.matchCase(), finder.matchCase, { [weak self] in
                    guard let finder = WindowsCore.finder else { return }
                    finder.matchCase.toggle()
                    self?.refresh()
                    self?.changed?()
                }),
                (Glyphs.wholeWords(), finder.wholeWords, { [weak self] in
                    guard let finder = WindowsCore.finder else { return }
                    finder.wholeWords.toggle()
                    self?.refresh()
                    self?.changed?()
                }),
            ], width: 60)
            optionsSlot.child = toggles
            buttons.children.append(Controls.cardButton(Words.t("Replace"), height: 26) { [weak self] in self?.replace() })
            let all = Controls.cardButton(Words.t("All"), height: 26) { [weak self] in self?.replaceAll() }
            try? ToolTipService.setToolTip(all, Words.t("Replace everything found, as one step"))
            buttons.children.append(all)
        }
        laidForSpelling = spelling
        if let replaced, !spelling {
            replacedLine.text = replaced == 1 ? Words.t("Replaced 1 time.") : Words.t("Replaced %lld times.", replaced)
            replacedLine.visibility = .visible
        } else {
            replacedLine.visibility = .collapsed
        }
    }

    private static func counted(_ n: Int, current: Int?, spelling: Bool, query: String) -> String {
        if spelling && n == 0 { return Words.t("No misspelt words") }
        if n == 0 { return query.isEmpty ? "" : Words.t("Not found") }
        if let current { return Words.t("%lld of %lld", current + 1, n) }
        return n == 1 ? Words.t("1 found") : Words.t("%lld found", n)
    }

    /// The misspelt word picked out, in the red it is marked with on the canvas.
    private func misspelt(_ finder: WindowsCore.Finder) -> FrameworkElement {
        let well = Theme.well(radius: 8)
        well.height = 26
        let words: TextBlock
        if let word = finder.misspeltWord {
            words = Theme.text(word, size: 12.5, weight: 500)
            words.foreground = Theme.brush(0xCC2929)
        } else {
            words = Theme.text(Words.t(finder.count == 0 ? "Every word is spelt right." : "Press Enter for the next misspelt word."), size: 12, ink: 2)
        }
        words.verticalAlignment = .center
        words.textTrimming = .characterEllipsis
        words.margin = Theme.inset(10, 0, 10, 0)
        well.child = words
        return well
    }

    /// A field in a well, 26 tall, as the Mac's find bar has them.
    private static func well(_ box: TextBox) -> Border {
        let well = Theme.well(radius: 8)
        well.height = 26
        box.fontFamily = Theme.ui
        box.fontSize = 12.5
        box.minWidth = 0
        box.minHeight = 0
        box.padding = Theme.inset(10, 4, 6, 0)
        box.verticalAlignment = .center
        box.borderThickness = Theme.inset(0)
        box.background = Theme.clear
        box.allowFocusOnInteraction = true
        for key in ["TextControlBackground", "TextControlBackgroundPointerOver", "TextControlBackgroundFocused",
                    "TextControlBorderBrush", "TextControlBorderBrushPointerOver", "TextControlBorderBrushFocused"] {
            _ = box.resources?.insert(key, Theme.clear)
        }
        for key in ["TextControlForeground", "TextControlForegroundPointerOver", "TextControlForegroundFocused"] {
            _ = box.resources?.insert(key, Theme.ink(1))
        }
        box.pointerPressed.addHandler { _, args in args?.handled = true }
        well.child = box
        return well
    }

    // MARK: The card's shadow

    private func drawShadow() {
        let scale = Double(root.xamlRoot?.rasterizationScale ?? 1)
        let w = root.actualWidth, h = root.actualHeight
        guard w > 0, h > 0 else { return }
        let pad = Int((30 * scale).rounded())
        let sw = Int((w * scale).rounded()), sh = Int((h * scale).rounded())
        var bitmap: WriteableBitmap?
        _ = WindowsCore.softShadow(width: sw, height: sh, pad: pad, blur: 14 * scale, dy: 0, colour: Theme.shadow, alpha: 0.16) { bw, bh in
            bitmap = WriteableBitmap(Int32(bw), Int32(bh))
            return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        try? bitmap?.invalidate()
        shadow.source = bitmap
        shadow.width = w + 2 * Double(pad) / scale
        shadow.height = h + 2 * Double(pad) / scale
        shadow.margin = Theme.inset(-Double(pad) / scale, -Double(pad) / scale + 6, -Double(pad) / scale, -Double(pad) / scale - 6)
    }
}
