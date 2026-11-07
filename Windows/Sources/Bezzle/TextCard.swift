import Foundation
import WinUI
import UWP
import BezzleCore

/// The Text card, as the Mac's TextCard: folded, the font and size, its dial setting the size
/// (caught at the sizes offered); open, the family and face, the size and its presets, how the
/// lines are aligned and the letters set, lists, how the box finds its size and where its lines
/// lie, then the spacing of lines, letters and paragraphs, the font's features and, for a
/// variable font, its axes. Pointing at a font, a face, a case, a feature or a size shows it on
/// the canvas before it is chosen.
extension Inspector {
    /// The sizes offered, as the Mac's Presets.textSizes.
    static let textSizes: [Double] = [12, 14, 16, 20, 24, 32, 48, 64]
    /// What lies inside a card, and a narrow field at the end of a row (the Mac's Inspector.content
    /// and endField): as wide as the last of three fields side by side.
    static let content = Theme.cardWidth - 24
    static let endField = (content - 16) / 3

    /// The family's own letters, for the fonts menu and the card's mark.
    static func font(of family: String) -> FontFamily? {
        // One of Windows' own by its name; an open one from its file beside Bezzle.
        if WindowsCore.isInstalled(family) { return FontFamily(family) }
        return WindowsCore.fontLook(of: family).map { FontFamily("ms-appx:///fonts/\($0.file)#\($0.family)") }
    }

    func textCard(_ t: WindowsCore.TextCard, ids: [UUID], board: Int) -> UIElement {
        @MainActor func edited() { session.edited(board: board) }
        @MainActor func change(_ c: WindowsCore.TextChange) {
            WindowsCore.change(ids, c)
            edited()
        }
        @MainActor func preview(_ c: WindowsCore.TextChange?) {
            WindowsCore.preview(ids, c)
            session.previewed(board: board)
        }
        // Once a menu closes, whatever it showed goes, unless what was chosen took its place.
        let unpreview: () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { if WindowsCore.endPreview() { self?.session.previewed(board: board) } } }
        }

        let summary = "\(t.familyShown) · \(t.size.map { "\(number($0)) pt" } ?? "Several")"
        let top = max(200, t.firstSize * 1.5)
        let dial = Dial(fraction: (t.firstSize - 1) / (top - 1),
                        set: { WindowsCore.change(ids, .size((1 + $0 * (top - 1)).rounded())) },
                        summary: { "\(t.familyShown) · \(self.number((1 + $0 * (top - 1)).rounded())) pt" },
                        stops: Self.textSizes.map { ($0 - 1) / (top - 1) })
        let mark = Theme.text("Aa", size: 12.5, weight: 500, ink: 2)
        if let family = t.family, family != "System", let font = Self.font(of: family) { mark.fontFamily = font }

        return card("Text", summary, mark: mark, dial: dial, style: "text", body: { [self] in
            var rows: [UIElement] = []
            // The family, in the face of it most like the one the letters have.
            rows.append(Controls.menuButton(t.familyShown, width: Self.content, menus: menus, searchable: true, entries: {
                WindowsCore.fontFamilies.map { f in
                    .item(WindowsCore.displayName(f), checked: f == t.family, font: f == "System" ? Theme.ui : Self.font(of: f),
                          preview: { on in preview(on ? .family(f) : nil) }) { change(.family(f)) }
                }
            }, closed: unpreview))
            let faces = Controls.menuButton(t.face ?? "Several", menus: menus, menuWidth: 200, entries: {
                t.faces.map { f in
                    .item(f, checked: f == t.face, preview: { on in preview(on ? .face(f) : nil) }) { change(.face(f)) }
                }
            }, closed: unpreview)
            let size = field("", t.size, unit: "pt", range: 1...2000, scrub: 0.25, width: Self.endField) { change(.size($0)) }
            rows.append(Controls.line([faces, size]))
            rows.append(Controls.presetStrip(Self.textSizes.enumerated().map { k, points in
                let digits = Theme.text(number(points), size: 9.5 + Double(k) * 0.75, weight: 500, ink: t.size == points ? 1 : 2)
                return (digits, t.size == points)
            }, width: Self.content, point: { k in preview(k.map { .size(Self.textSizes[$0]) }) }, choose: { k in
                change(.size(Self.textSizes[k]))
            }))
            let aligns = Controls.iconChoice(t.align, ["left", "center", "right", "justify"].map { ($0, Glyphs.textAlign($0)) }) { change(.align($0)) }
            let lines = Controls.iconToggles([
                (Glyphs.underline(), t.underline, { change(.underline(!t.underline)) }),
                (Glyphs.strikethrough(), t.strikethrough, { change(.strikethrough(!t.strikethrough)) }),
            ], width: Self.endField)
            rows.append(Controls.line([aligns, lines]))
            let lists = Controls.iconToggles([
                (Glyphs.list(numbered: false), t.list == "bullet", { change(.list(t.list == "bullet" ? nil : "bullet")) }),
                (Glyphs.list(numbered: true), t.list == "number", { change(.list(t.list == "number" ? nil : "number")) }),
            ], width: Self.column)
            rows.append(Controls.line([lists, caseMenu(t, change: change, preview: preview, closed: unpreview)]))
            // How the box finds its size, and, for a box of fixed size, where the lines lie in it.
            let sizing = Controls.iconChoice(t.sizing, [
                ("autoWidth", Glyphs.bothWays(across: true)), ("autoHeight", Glyphs.bothWays(across: false)), ("fixed", Glyphs.dashedBox()),
            ]) { change(.sizing($0)) }
            let vertical = Controls.iconChoice(t.vertical, [
                ("top", Glyphs.align(.top, size: 14)), ("middle", Glyphs.align(.centerY, size: 14)), ("bottom", Glyphs.align(.bottom, size: 14)),
            ]) { change(.vertical($0)) }
            rows.append(Controls.line([sizing, vertical]))

            // The exact numbers.
            rows.append(pair(field("Line", t.lineSpacing, range: 0...4000, scrub: 0.25) { change(.lineSpacing($0)) },
                             field("Letter", t.tracking, range: -500...2000) { change(.tracking($0)) }))
            let features = featuresMenu(t, change: change, preview: preview, closed: unpreview)
            features.width = Self.column
            rows.append(pair(field("¶", t.paragraphSpacing, range: 0...4000, scrub: 0.25) { change(.paragraphSpacing($0)) }, features))
            if !t.axes.isEmpty { rows += axesBlock(t, change: change) }
            return rows
        })
    }

    /// How the letters are set, whatever was typed.
    private func caseMenu(_ t: WindowsCore.TextCard, change: @escaping @MainActor (WindowsCore.TextChange) -> Void,
                          preview: @escaping @MainActor (WindowsCore.TextChange?) -> Void, closed: @escaping () -> Void) -> FrameworkElement {
        let options: [(String, String)] = [("", "As Typed"), ("upper", "Uppercase"), ("lower", "Lowercase"), ("title", "Title Case"), ("smallCaps", "Small Caps")]
        let title = Words.t(t.letterCase.map { now in options.first { $0.0 == now }?.1 ?? "As Typed" } ?? "Several")
        return Controls.menuButton(title, menus: menus, menuWidth: 180, entries: {
            options.map { value, name in
                let raw: String? = value.isEmpty ? nil : value
                return .item(name, checked: t.letterCase == value, preview: { on in preview(on ? .letterCase(raw) : nil) }) { change(.letterCase(raw)) }
            }
        }, closed: closed)
    }

    /// The font's OpenType features: figures, ligatures, stylistic sets. Each ticked when on;
    /// pointing at one shows it turned the other way.
    private func featuresMenu(_ t: WindowsCore.TextCard, change: @escaping @MainActor (WindowsCore.TextChange) -> Void,
                              preview: @escaping @MainActor (WindowsCore.TextChange?) -> Void, closed: @escaping () -> Void) -> FrameworkElement {
        let title = t.features.isEmpty ? "No Features" : t.featuresChanged == 0 ? "Features" : "\(t.featuresChanged) Features"
        return Controls.menuButton(title, menus: menus, menuWidth: 260, entries: {
            var entries: [MenuHost.Entry] = []
            var group = 0
            for f in t.features {
                if f.group != group, !entries.isEmpty { entries.append(.separator) }
                group = f.group
                entries.append(.item(f.name, checked: f.on, preview: { on in preview(on ? .feature(f.tag, from: f.on) : nil) }) {
                    change(.feature(f.tag, from: f.on))
                })
            }
            return entries.isEmpty ? [.note("This font has no OpenType features to turn on.")] : entries
        }, closed: closed)
    }

    /// The axes, folded under one line until opened or one is set.
    private func axesBlock(_ t: WindowsCore.TextCard, change: @escaping @MainActor (WindowsCore.TextChange) -> Void) -> [UIElement] {
        let open = showsAxes || t.axesSet
        let head = Grid()
        head.height = 22
        head.background = Theme.clear
        for w in [GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star), GridLength(value: 1, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = w
            head.columnDefinitions.append(column)
        }
        let title = Theme.text(Words.t("Variable Font"), size: 12, ink: 2)
        title.verticalAlignment = .center
        head.children.append(title)
        let names = Theme.text(t.axes.map(\.name).joined(separator: ", "), size: 11, ink: 3)
        names.verticalAlignment = .center
        names.horizontalAlignment = .right
        names.textTrimming = .characterEllipsis
        names.margin = Theme.inset(4, 0, 6, 0)
        names.opacity = open ? 0 : 1
        try? Grid.setColumn(names, 1)
        head.children.append(names)
        let chevron = Glyphs.view(Glyphs.chevron(up: open), size: 9, brush: Theme.ink(3))
        chevron.verticalAlignment = .center
        try? Grid.setColumn(chevron, 2)
        head.children.append(chevron)
        head.pointerPressed.addHandler { _, args in args?.handled = true }
        head.tapped.addHandler { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self else { return }
                self.showsAxes.toggle()
                self.show()
            } }
        }
        var rows: [UIElement] = [head]
        guard open else { return rows }
        for axis in t.axes {
            let span = axis.high - axis.low
            rows.append(Controls.row(axis.name, field("", axis.value, range: axis.low...axis.high, scrub: span / 300) { change(.axis(axis.tag, $0)) }))
        }
        return rows
    }
}
