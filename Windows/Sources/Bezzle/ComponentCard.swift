import Foundation
import WinUI
import WinAppSDK
import WindowsFoundation
import BezzleCore

/// The Component card, as the Mac's (Views/ComponentCard.swift): a copy of a component, or a layer
/// in one, picked. Folded, it names the component (or the variant it shows) and turns from this
/// copy to the next wherever it is used. Open, it names the component and shows its variants,
/// each drawn as this copy would look as it: pointing at one shows the copy turning into it on
/// the canvas, a click makes it so, a double click renames it, and the last tile makes a new one.
/// Pulled off (its ×), the copy is unlinked: a group like any other, as it looks.
extension Inspector {
    func componentCard(_ ids: [UUID], board: Int) -> UIElement? {
        guard ids.count == 1, let look = WindowsCore.componentLook(ids), !look.locked else { return nil }
        let session = session
        // Swift on Windows can't type-check a closure inside a ternary.
        var unlink: (@MainActor () -> Void)?
        if look.whole {
            unlink = {
                WindowsCore.unlink(ids)
                session.edited(board: board)
            }
        }
        let current = look.variants.firstIndex { $0 == look.current } ?? 0
        let summary = look.variants.count > 1 ? look.names[current] : (look.count > 1 ? "" : look.name)
        let mark = Glyphs.view(Glyphs.component(size: 13), size: 13, brush: Theme.brush(Theme.linked))
        return card("Component", summary, mark: mark, remove: unlink, removal: "Unlink from component",
                    accessory: look.count > 1 ? copyTurner(look, ids: ids) : nil) { [self] in
            var rows: [UIElement] = []
            rows.append(Controls.entry(look.name, placeholder: "Name") { typed in
                let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                WindowsCore.renameComponent(of: look.copy, to: name)
                session.edited(board: nil)
                return name
            })
            // Taken from another design: which, quietly.
            if let from = look.from {
                let words = Theme.text("From \u{201C}\(from)\u{201D}", size: 11, ink: 3)
                words.textTrimming = .characterEllipsis
                rows.append(words)
            }
            rows.append(variantTiles(look, ids: ids, board: board))
            if look.ownLooks {
                let button = ExportSheet.textButton("Look Like the Others") {
                    WindowsCore.resetCopy(look.copy)
                    session.edited(board: nil)
                }
                try? ToolTipService.setToolTip(button as? DependencyObject,
                                               "Lets this copy follow its component again in everything it keeps of its own, but its words and pictures")
                rows.append(button)
            }
            return rows
        }
    }

    /// A layer in a copy keeping looks of its own, as the Mac's CopyLayerCard: what it keeps, and
    /// Follow the Others, which lets it follow its component again.
    func copyLayerCard(_ ids: [UUID], board: Int) -> UIElement? {
        guard ids.count == 1, WindowsCore.componentLook(ids)?.copy != ids[0], let own = WindowsCore.ownLooks(ids[0]) else { return nil }
        let session = session
        let follow = ExportSheet.textButton("Follow the Others") {
            WindowsCore.followComponent(ids)
            session.edited(board: nil)
        } as? FrameworkElement
        // Kept from the line under it, which would fold the card.
        follow?.pointerPressed.addHandler { _, args in args?.handled = true }
        return card("Only in this copy", own, glyph: Glyphs.pin(size: 14), accessory: follow)
    }

    /// The copy before and after among the component's copies, and which this is: "2 of 5".
    private func copyTurner(_ look: WindowsCore.ComponentLook, ids: [UUID]) -> FrameworkElement {
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 2
        row.verticalAlignment = .center
        let session = session
        func turn(_ step: Int) {
            guard let next = WindowsCore.copy(step, from: ids) else { return }
            session.select([next], on: WindowsCore.board(of: next))
        }
        let back = Controls.iconButton(Glyphs.back(size: 9), size: 22) { turn(-1) }
        try? ToolTipService.setToolTip(back, "The copy before")
        // Kept from the line under them, which would fold the card.
        back.pointerPressed.addHandler { _, args in args?.handled = true }
        row.children.append(back)
        let place = Theme.text("\(look.index + 1) of \(look.count)", size: 12)
        place.minWidth = 44
        place.textAlignment = .center
        place.verticalAlignment = .center
        row.children.append(place)
        let next = Controls.iconButton(Glyphs.chevron(open: false, size: 9), size: 22) { turn(1) }
        try? ToolTipService.setToolTip(next, "The copy after")
        next.pointerPressed.addHandler { _, args in args?.handled = true }
        row.children.append(next)
        return row
    }

    /// The component's variants as tiles, three to a row, the one the copy shows ringed; then one
    /// that makes a new variant of the copy as it looks.
    private func variantTiles(_ look: WindowsCore.ComponentLook, ids: [UUID], board: Int) -> UIElement {
        let grid = Grid()
        for _ in 0..<3 {
            let column = ColumnDefinition()
            column.width = GridLength(value: 1, gridUnitType: .star)
            grid.columnDefinitions.append(column)
        }
        grid.columnSpacing = 8
        grid.rowSpacing = 8
        let count = look.variants.count + 1
        for _ in 0..<((count + 2) / 3) { grid.rowDefinitions.append(RowDefinition()) }
        let session = session
        for (k, v) in look.variants.enumerated() {
            let tile = variantTile(look, variant: v, name: look.names[k], chosen: v == look.current, ids: ids, board: board)
            try? Grid.setColumn(tile, Int32(k % 3))
            try? Grid.setRow(tile, Int32(k / 3))
            grid.children.append(tile)
        }
        // A new variant, of the copy as it looks.
        let new = Pressable(radius: 7) {
            let picked = WindowsCore.addVariant(ids)
            session.select(picked, on: board)
            session.edited(board: nil)
        }
        new.hoverWash = 0.05
        new.box.height = 44
        new.box.borderBrush = Theme.brush(Theme.ink, 0.2)
        new.box.borderThickness = Theme.inset(1)
        let plus = Glyphs.view(Glyphs.plus(size: 14), size: 14, brush: Theme.ink(2))
        plus.horizontalAlignment = .center
        plus.verticalAlignment = .center
        new.box.child = plus
        try? ToolTipService.setToolTip(new.box, "New variant, of this copy as it looks")
        try? Grid.setColumn(new.box, Int32(look.variants.count % 3))
        try? Grid.setRow(new.box, Int32(look.variants.count / 3))
        new.box.verticalAlignment = .top
        grid.children.append(new.box)
        return grid
    }

    private func variantTile(_ look: WindowsCore.ComponentLook, variant v: Int?, name: String, chosen: Bool,
                             ids: [UUID], board: Int) -> FrameworkElement {
        let session = session
        let stack = StackPanel()
        stack.spacing = 4
        let press = Pressable(radius: 7) {
            WindowsCore.previewVariant(v, of: look.copy, false)
            guard !chosen else { return }
            let picked = WindowsCore.setVariant(v, ids)
            session.select(picked, on: board)
            session.edited(board: nil)
        }
        press.hoverWash = 0
        press.box.height = 44
        press.box.background = Theme.brush(Theme.card)
        press.box.borderBrush = chosen ? Theme.brush(Theme.linked) : Theme.brush(Theme.ink, 0.12)
        press.box.borderThickness = Theme.inset(chosen ? 2 : 1)
        let picture = Inspector.rendered(CGSize(width: 64, height: 40)) { scale, fill in
            WindowsCore.variantPicture(of: look.copy, v, size: CGSize(width: 64, height: 40), scale: scale, into: fill)
        }
        picture.horizontalAlignment = .center
        picture.verticalAlignment = .center
        press.box.child = picture
        // The copy turned into this variant on the canvas, before it is chosen.
        press.box.pointerEntered.addHandler { _, _ in
            guard !chosen else { return }
            WindowsCore.previewVariant(v, of: look.copy, true)
            session.previewed(board: nil)
        }
        press.box.pointerExited.addHandler { _, _ in
            guard !chosen, WindowsCore.endPreview() else { return }
            session.previewed(board: nil)
        }
        stack.children.append(press.box)
        let label = Border()
        let words = Theme.text(name, size: 11)
        words.foreground = chosen ? Theme.brush(Theme.linked) : Theme.ink(2)
        words.textTrimming = .characterEllipsis
        words.horizontalAlignment = .center
        label.child = words
        // A double click on the name renames the variant, there.
        label.background = Theme.clear
        label.doubleTapped.addHandler { [weak label] _, _ in
            guard let label else { return }
            label.child = Controls.entry(name, placeholder: "Name") { typed in
                WindowsCore.renameVariant(v, of: look.copy, to: typed)
                session.edited(board: nil)
                return typed
            }
        }
        stack.children.append(label)
        // Its menu: rename it, or take it away, but for the first.
        if let v {
            stack.rightTapped.addHandler { [weak self] _, args in
                guard let self, let menus = self.menus, let at = try? args?.getPosition(nil) else { return }
                args?.handled = true
                menus.show(at: CGPoint(x: Double(at.x), y: Double(at.y)), width: 180, entries: [
                    .item("Delete Variant") {
                        WindowsCore.removeVariant(v, of: look.copy)
                        session.edited(board: nil)
                    },
                ])
            }
        }
        return stack
    }
}
