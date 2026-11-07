import Foundation

// Taking from other designs as the design itself: a style given to layers, what bringing several
// components brings along, and a design brought up to date with a library. The Mac's store
// (Store/LibraryShelf.swift) and Windows call these. See `LibraryLink`.

extension Node {
    /// A style given to this layer where a style of its kind goes: the place the inspector has
    /// open (`open`), if it is of that kind, else the first fill (a text's letters), its type, its
    /// first shadow or its corners. What it goes on is turned on, so it shows. With `naming`, the
    /// layer is named after the style too.
    mutating func give(_ style: Style, at open: StylePlace?, dark: Bool, naming: Bool = true) {
        let place: StylePlace
        if let open, open.kind == style.kind {
            place = open
        } else {
            switch style.kind {
            case .colour: place = .fill(0)
            case .text: place = .text
            case .shadow: place = .shadow(0)
            case .corners: place = .corners
            }
        }
        let look = style.look(dark: dark)
        guard !locked, place.look(of: self) != nil, place.takes(look, in: self) else { return }
        if naming { place.name(style.id, in: &self) }
        place.apply(look, to: &self)
        switch place {
        case .fill(let i) where kind != .text: self[fill: i].on = true
        case .shadow(let i): self[shadow: i].on = true
        default: break
        }
        if place == .text { refit() }
    }
}

extension BezzleDocument {
    /// Brings a style of another design into this one, as `take` has it, and gives it to the
    /// layers `targets` at `open`.
    mutating func use(_ styleID: UUID, taking take: LibraryTake, on targets: [UUID], at open: StylePlace?) {
        let map = bring(take)
        guard let style = self.style(map[styleID] ?? styleID) else { return }
        for id in targets {
            update(id) { n in n.give(style, at: open, dark: false) }
        }
    }

    /// Brought up to date with a library, as `update(from:)` does, with the copies and the layers
    /// named after the styles following as a change does: for showing it before it is made.
    mutating func updating(from library: LibraryContent, masters: [UUID], styles: [UUID]) {
        let before = self
        update(from: library, masters: masters, styles: styles)
        syncComponents(since: before)
        syncStyles(since: before)
    }
}

nonisolated extension LibraryContent {
    /// What bringing several components up to date brings along.
    func taking(_ ids: [UUID]) -> LibraryTake {
        var take = LibraryTake(url: url, name: name)
        var seen = Set<UUID>()
        for id in ids {
            let t = taking(id)
            for m in t.masters where seen.insert(m.id).inserted { take.masters.append(m) }
            for s in t.styles where !take.styles.contains(where: { $0.id == s.id }) { take.styles.append(s) }
        }
        return take
    }
}
