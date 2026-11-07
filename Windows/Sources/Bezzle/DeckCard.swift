import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// A stack's cards in the inspector, as the Mac's Views/DeckInspector.swift: which post is in front,
/// of how many, turning from one to the next on its folded line; and a layer of a post that keeps
/// something of its own, what, and how to let it follow the other posts again. Adding, seeing them
/// all and the rest are on the canvas, on the stack itself.
extension Inspector {
    /// For a deck selected alone.
    func deckCard(_ ids: [UUID], board: Int) -> UIElement? {
        guard ids.count == 1, let deck = WindowsCore.deck(ids[0]) else { return nil }
        return card("Post", "", glyph: Glyphs.stack(size: 14), accessory: postTurner(deck))
    }

    /// For one layer of a post that keeps something of its own.
    func postLayerCard(_ ids: [UUID], board: Int) -> UIElement? {
        guard ids.count == 1, let own = WindowsCore.ownWords(ids[0]) else { return nil }
        let session = session
        let follow = ExportSheet.textButton("Follow the Others") {
            WindowsCore.followDesign(ids)
            session.edited(board: nil)
        } as? FrameworkElement
        // Kept from the line under it, which would fold the card.
        follow?.pointerPressed.addHandler { _, args in args?.handled = true }
        return card("Only in this post", own, glyph: Glyphs.pin(size: 14), accessory: follow)
    }

    /// The post before and after, and which is in front: "2 of 5".
    private func postTurner(_ deck: WindowsCore.DeckLook) -> FrameworkElement {
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 2
        row.verticalAlignment = .center
        let session = session
        func turn(_ step: Int) {
            guard let ids = WindowsCore.turnPage(by: step, deck: deck.id, selection: session.selection) else { return }
            session.select(ids, on: session.board)
            session.previewed(board: nil)
        }
        let back = Controls.iconButton(Glyphs.back(size: 9), size: 22) { turn(-1) }
        try? ToolTipService.setToolTip(back, Words.t("The post before (Page Up)"))
        back.pointerPressed.addHandler { _, args in args?.handled = true }
        if deck.index == 0 { back.opacity = 0.35; back.isHitTestVisible = false }
        row.children.append(back)
        let place = Theme.text(Words.t("%lld of %lld", deck.index + 1, deck.count), size: 12)
        place.minWidth = 44
        place.textAlignment = .center
        place.verticalAlignment = .center
        row.children.append(place)
        let next = Controls.iconButton(Glyphs.chevron(open: false, size: 9), size: 22) { turn(1) }
        try? ToolTipService.setToolTip(next, Words.t("The post after (Page Down)"))
        next.pointerPressed.addHandler { _, args in args?.handled = true }
        if deck.index >= deck.count - 1 { next.opacity = 0.35; next.isHitTestVisible = false }
        row.children.append(next)
        return row
    }
}
