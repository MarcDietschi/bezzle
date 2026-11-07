import Foundation
import WinUI
import BezzleCore

/// The Artboard card, as the Mac's (SelectionInspector.artboardCard): its size from the presets,
/// pointing at one in the menu showing the design laid out for it; made a carousel of a format;
/// whether its layers adapt to a new size, and whether it clips them. A carousel's card says its
/// format and slides instead: the format, a slide's width and height, and how many slides.
extension Inspector {
    func artboardCard(_ id: UUID, board: Int) -> UIElement? {
        guard let a = WindowsCore.artboardCard(id) else { return nil }
        @MainActor func edited() { session.edited(board: nil) }
        var summary = a.preset ?? "Custom"
        if a.isCarousel {
            let format = a.format ?? a.slide.map { "\(number(Double($0.width))) × \(number(Double($0.height)))" }
            summary = [format, a.slides == 1 ? "1 slide" : "\(a.slides) slides"].compactMap { $0 }.joined(separator: " · ")
        }
        return card(a.isCarousel ? "Carousel" : "Artboard", summary, id: "Artboard",
                    mark: Glyphs.frame(size: a.size, box: 15, slides: a.isCarousel ? a.slides : 1), body: { [self] in
            var rows: [UIElement] = []
            if a.isCarousel {
                rows += carouselRows(a, id: id, edited: edited)
            } else {
                rows.append(Controls.row("Size", Controls.menuButton(a.preset ?? "Custom", menus: menus, menuWidth: 230, entries: { [self] in
                    sizeEntries(a, id: id, board: board, edited: edited)
                }, closed: { [self] in
                    if WindowsCore.endPreview() { session.previewed(board: nil) }
                })))
                rows.append(Controls.row("Adapt layout", Controls.toggle(a.adapts) { on in
                    WindowsCore.setAdapts([id], on)
                    edited()
                }))
            }
            rows.append(Controls.row("Clip content", Controls.toggle(a.clips) { on in
                WindowsCore.setClips([id], on)
                edited()
            }))
            return rows
        })
    }

    /// The Size menu: the presets by group, each with its size, the one it is ticked; pointing at
    /// one shows the design laid out for it. Then the carousels' formats.
    private func sizeEntries(_ a: WindowsCore.ArtboardCard, id: UUID, board: Int, edited: @escaping @MainActor () -> Void) -> [MenuHost.Entry] {
        var entries: [MenuHost.Entry] = []
        for (i, group) in WindowsCore.presetGroups.enumerated() {
            if i > 0 { entries.append(.separator) }
            entries.append(.note(group.title))
            for p in group.presets {
                entries.append(.item(p.title, detail: "\(Int(p.size.width)) × \(Int(p.size.height))", checked: p.title == a.preset && p.size == a.size,
                                     preview: { [self] on in
                                         WindowsCore.previewArtboard(id, size: on ? p.size : nil)
                                         session.previewed(board: nil)
                                     }) {
                    WindowsCore.resizeArtboards([id], to: p.size)
                    edited()
                })
            }
        }
        entries.append(.separator)
        // Its layers stay where they are on it.
        for f in WindowsCore.carouselFormats {
            entries.append(.item("Carousel, \(f.title)", detail: "\(Int(f.size.width)) × \(Int(f.size.height))") {
                WindowsCore.makeCarousel([id], slide: f.size)
                edited()
            })
        }
        return entries
    }

    /// A carousel's format, its slides' width and height, and how many slides it has. Its layers
    /// stay where they are on it when either changes.
    private func carouselRows(_ a: WindowsCore.ArtboardCard, id: UUID, edited: @escaping @MainActor () -> Void) -> [UIElement] {
        let slide = a.slide ?? a.size
        let counts = WindowsCore.slideCounts
        var rows: [UIElement] = []
        rows.append(Controls.row("Format", Controls.menuButton(a.format ?? "Custom", menus: menus, menuWidth: 250, entries: {
            WindowsCore.carouselFormats.map { f in
                MenuHost.Entry.item(f.title, detail: "\(Int(f.size.width)) × \(Int(f.size.height))", checked: f.size == a.slide) {
                    WindowsCore.setSlideSize([id], f.size)
                    edited()
                }
            } + [.separator, .item("Plain artboard") {
                WindowsCore.setSlideSize([id], nil)
                edited()
            }]
        })))
        rows.append(pair(field("W", Double(slide.width), range: 1...100_000) { WindowsCore.setSlideSide([id], width: $0); edited() },
                         field("H", Double(slide.height), range: 1...100_000) { WindowsCore.setSlideSide([id], height: $0); edited() }))
        let fewer = Controls.iconButton(Glyphs.minus(size: 14), size: Controls.height) {
            WindowsCore.setSlides([id]) { $0 - 1 }
            edited()
        }
        fewer.opacity = a.slides > counts.lowerBound ? 1 : 0.35
        fewer.isHitTestVisible = a.slides > counts.lowerBound
        let more = Controls.iconButton(Glyphs.plus(size: 14), size: Controls.height) {
            WindowsCore.setSlides([id]) { $0 + 1 }
            edited()
        }
        more.opacity = a.slides < counts.upperBound ? 1 : 0.35
        more.isHitTestVisible = a.slides < counts.upperBound
        let count = field("", Double(a.slides), range: Double(counts.lowerBound)...Double(counts.upperBound), scrub: 0.05,
                          width: Theme.cardWidth - 24 - Inspector.column - Inspector.columnGap - 2 * Controls.height - 8) { v in
            WindowsCore.setSlides([id]) { _ in Int(v.rounded()) }
            edited()
        }
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 4
        for e in [fewer, count, more] { row.children.append(e) }
        rows.append(Controls.row("Slides", row))
        if let platforms = a.platforms {
            rows.append(Controls.caption("For \(platforms). Up to \(counts.upperBound) slides."))
        }
        return rows
    }
}
