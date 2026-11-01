import SwiftUI
import AppKit
import CoreText

/// The type of the selected text layers: their font, size, how their lines are set, and the rest.
/// While typing with letters picked out, what is about letters (font, size, letter spacing, lines
/// under and through them, lists) is about those letters alone; the rest is about the whole layer.
struct TextCard: View {
    @Environment(MenuHost.self) private var menus
    let store: DocumentStore
    let nodes: [Node]
    var live = false
    /// Whether a variable font's axes are shown, which they are anyway once one is set.
    @State private var showsAxes = false

    /// The letters picked out while typing, if any: what the letter controls change.
    private var picked: NSRange? { store.pickedLetters }

    /// How the letters shown look, a run's worth each.
    private var letters: [Letters] { store.lettersShown(in: nodes) }

    /// What every one of `items` has alike, or nil when they differ.
    private func alike<T: Equatable, I>(_ items: [I], _ value: (I) -> T) -> T? {
        guard let first = items.first.map(value) else { return nil }
        return items.allSatisfy { value($0) == first } ? first : nil
    }

    private func common<T: Equatable>(_ value: (TextStyle) -> T) -> T? {
        alike(nodes.map { $0.style ?? TextStyle() }, value)
    }

    private func letter<T: Equatable>(_ value: (Letters) -> T) -> T? { alike(letters, value) }

    /// Changes what is about the whole layer.
    private func set(_ action: LocalizedStringResource, _ change: @escaping (inout TextStyle) -> Void) {
        store.updateSelection(action) { n in
            guard n.kind == .text else { return }
            var s = n.style ?? TextStyle()
            change(&s)
            n.style = s
        }
    }

    /// Changes what is about letters: those picked out, or all of them.
    private func restyle(_ action: LocalizedStringResource, _ change: @escaping (inout Letters) -> Void) {
        store.restyleLetters(action, change)
    }

    /// Shows a change on the canvas without making it, such as the font pointed at in the font
    /// menu; nil takes it away. Letters picked out while typing are in the editor, which shows
    /// what is chosen once it is.
    private func preview(_ change: ((inout Letters) -> Void)?) {
        guard picked == nil else { return }
        store.showPreview("font", change.map { change in { n in n.restyleLetters(in: nil, change) } })
    }

    private func previewStyle(_ change: ((inout TextStyle) -> Void)?) {
        store.showPreview("font", change.map { change in { n in
            var s = n.style ?? TextStyle()
            change(&s)
            n.style = s
        } })
    }

    var body: some View {
        let family = letter(\.family)
        let face = letter(\.face)
        let size = letter { Double($0.size) }
        let first = letters.first ?? TextLook.plain.resolved(over: TextStyle(), color: .black)
        let summary = [family.map { Fonts.displayName($0) } ?? String(localized: "Several fonts"),
                       size.map { "\(SelectionInspector.said($0)) pt" } ?? SelectionInspector.several].joined(separator: " · ")
        let dial = Dial(value: Double(first.size), range: 1...max(200, Double(first.size) * 1.5), stops: Presets.textSizes.map(Double.init),
                        step: 1, action: "Change Size") { v in restyle("Change Size") { $0.size = CGFloat(v.rounded()) } }
        AspectCard(aspect: .text, title: "Text", summary: summary, dial: dial, live: live) {
            Text(verbatim: "Aa")
                .font(family.flatMap { $0 != TextStyle.system && Fonts.showsOwnName($0) ? Font.custom($0, size: 12.5) : nil } ?? .system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .fixedSize()
        } picks: {
            if let picked {
                Caption(picked.length == 1 ? "Changing the letter picked out." : "Changing the \(picked.length) letters picked out.")
                    .transition(.unfold)
            }
            MenuButton(id: "font-family", title: family.map { .verbatim(Fonts.displayName($0)) } ?? "Several fonts", width: Inspector.content, fills: true) {
                familyEntries(current: family)
            }
            HStack(spacing: 8) {
                MenuButton(id: "font-face", title: face.map { .verbatim($0) } ?? "Several", width: 200, fills: true) {
                    Fonts.faces(of: family ?? first.family).map { f in
                        MenuEntry.item(.verbatim(f), checked: f == face, preview: { on in preview(on ? { $0.face = f } : nil) }) {
                            restyle("Change Font") { $0.face = f }
                        }
                    }
                }
                NumberField(label: "", value: size, unit: "pt", range: 1...2000, scrub: 0.25, action: "Change Size") { v in
                    restyle("Change Size") { $0.size = CGFloat(v) }
                } each: { f in
                    restyle("Change Size") { $0.size = CGFloat(f(Double($0.size))) }
                }
                .frame(width: Inspector.endField)
            }
            PresetStrip(action: "Change Size", items: Presets.textSizes.map { points in
                PresetItem(id: "text-size-\(Int(points))", name: "\(Int(points)) points", active: size == Double(points)) { n in
                    n.restyleLetters(in: picked) { $0.size = points }
                }
            }) { item in
                let points = Presets.textSizes.first { "text-size-\(Int($0))" == item.id } ?? 12
                Text(verbatim: "\(Int(points))")
                    .font(.system(size: 9.5 + CGFloat(Presets.textSizes.firstIndex(of: points) ?? 0) * 0.75, weight: .medium).monospacedDigit())
            }
            HStack(spacing: 8) {
                IconChoice(selection: common(\.align), options: [
                    (.left, "text.alignleft", "Align left"),
                    (.center, "text.aligncenter", LocalizedStringResource("text.align-centre", defaultValue: "Centre", comment: "Centres the text, beside Align left and Align right.")),
                    (.right, "text.alignright", "Align right"),
                    (.justify, "text.justify", "Justify"),
                ]) { a in set("Align Text") { $0.align = a } }
                IconToggles(options: [
                    ("underline", "Underline  ⌘U", letter(\.underline) == true, { store.toggleUnderline() }),
                    ("strikethrough", "Strikethrough  ⇧⌘X", letter(\.strikethrough) == true, { store.toggleStrikethrough() }),
                ])
                .frame(width: Inspector.endField)
            }
            HStack(spacing: 8) {
                IconToggles(options: [
                    ("list.bullet", "Bulleted list  ⇧⌘8", letter(\.list) == .bullet, { store.toggleList(.bullet) }),
                    ("list.number", "Numbered list  ⇧⌘7", letter(\.list) == .number, { store.toggleList(.number) }),
                ])
                .frame(width: Inspector.column)
                caseMenu
            }
            // How the box finds its size, and, for a box of fixed size, where the lines lie in it.
            HStack(spacing: 8) {
                IconChoice(selection: common(\.sizing), options: [
                    (.autoWidth, "arrow.left.and.right", "Auto size"),
                    (.autoHeight, "arrow.up.and.down", "Fixed width"),
                    (.fixed, "rectangle.dashed", "Fixed size"),
                ]) { v in
                    let action: LocalizedStringResource = switch v {
                    case .autoWidth: "Auto Size"
                    case .autoHeight: "Fixed Width"
                    case .fixed: "Fixed Size"
                    }
                    set(action) { $0.sizing = v }
                }
                let fixed = common(\.sizing) == .fixed
                IconChoice(selection: fixed ? common { $0.vertical ?? .top } : nil, options: [
                    (.top, "align.vertical.top", "Lines at the top"),
                    (.middle, "align.vertical.center", "Lines in the middle"),
                    (.bottom, "align.vertical.bottom", "Lines at the bottom"),
                ]) { v in
                    // Only a box of fixed size has room for its lines to lie anywhere: it becomes one.
                    set("Place Lines") {
                        $0.sizing = .fixed
                        $0.vertical = v == .top ? nil : v
                    }
                }
            }
        } exact: {
            Pair(lineField, letterField)
            Pair(NumberField(label: .verbatim("¶"), value: common { Double($0.paragraphSpacing ?? 0) }, range: 0...4000, scrub: 0.25,
                             action: "Change Paragraph Spacing") { v in
                                 set("Change Paragraph Spacing") { $0.paragraphSpacing = v > 0 ? CGFloat(v) : nil }
                             } each: { f in
                                 set("Change Paragraph Spacing") { s in
                                     let v = f(Double(s.paragraphSpacing ?? 0))
                                     s.paragraphSpacing = v > 0 ? CGFloat(v) : nil
                                 }
                             }
                             .help("Space after each paragraph"),
                 featuresMenu)
            if !axes.isEmpty { axesBlock }
        }
        .animation(Theme.unfold, value: picked != nil)
        .animation(Theme.quick, value: common(\.sizing))
    }

    // MARK: Spacing

    private var lineField: some View {
        NumberField(label: LocalizedStringResource("text.line-spacing", defaultValue: "Line", comment: "The distance between lines of text, beside the letter spacing."),
                    value: lineSpacing, range: 0...4000, scrub: 0.25, action: "Change Line Spacing") { v in
            set("Change Line Spacing") { $0.lineSpacing = CGFloat(v) }
        } each: { f in
            set("Change Line Spacing") { $0.lineSpacing = CGFloat(f(Double($0.lineSpacing ?? Self.naturalLineHeight($0)))) }
        }
    }

    private var letterField: some View {
        NumberField(label: "Letter", value: letter { Double($0.tracking) }, range: -500...2000, scrub: 1, decimals: 0, action: "Change Letter Spacing") { v in
            restyle("Change Letter Spacing") { $0.tracking = CGFloat(v) }
        } each: { f in
            restyle("Change Letter Spacing") { $0.tracking = CGFloat(f(Double($0.tracking))) }
        }
    }

    /// The font's own line height, which the text has until one is set.
    private static func naturalLineHeight(_ style: TextStyle) -> CGFloat {
        let font = Fonts.font(style)
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// The line spacing they share, or the font's own line height until one is set.
    private var lineSpacing: Double? {
        if let set = common(\.lineSpacing) {
            if let set { return Double(set) }
            guard let style = nodes.first?.style else { return nil }
            return Double(Self.naturalLineHeight(style))
        }
        return nil
    }

    // MARK: Case

    private var caseMenu: some View {
        let now = common(\.letterCase)
        let options: [(LetterCase?, LocalizedStringResource)] = [
            (nil, LocalizedStringResource("text.case-typed", defaultValue: "As Typed", comment: "Letters set as they were typed, beside Uppercase and the others.")),
            (.upper, "Uppercase"), (.lower, "Lowercase"), (.title, "Title Case"), (.smallCaps, "Small Caps"),
        ]
        let title = now.map { n in options.first { $0.0 == n }?.1 ?? "As Typed" } ?? "Several"
        return MenuButton(id: "text-case", title: title, width: 180, fills: true) {
            options.map { value, name in
                MenuEntry.item(name, checked: now == .some(value), preview: { on in previewStyle(on ? { $0.letterCase = value } : nil) }) {
                    set("Change Case") { $0.letterCase = value }
                }
            }
        }
        .help("How the letters are set, whatever was typed")
    }

    // MARK: Features

    /// The layers' font as their style has it, for what it offers.
    private var baseFont: NSFont { Fonts.font(nodes.first?.style ?? TextStyle()) }

    /// Features that are on unless turned off.
    private static let onByDefault: Set<String> = ["liga", "calt"]

    /// What each feature is called here, when the font's own name says little; in the order they show.
    private static let known: [(tag: String, name: LocalizedStringResource)] = [
        ("liga", "Ligatures"), ("dlig", "Rare Ligatures"), ("calt", "Contextual Alternates"),
        ("onum", "Old-Style Figures"), ("lnum", "Lining Figures"), ("tnum", "Tabular Figures"), ("pnum", "Proportional Figures"),
        ("zero", "Slashed Zero"), ("frac", "Fractions"), ("sups", "Superscript"), ("subs", "Subscript"), ("ordn", "Ordinals"),
        ("case", "Case-Sensitive Forms"), ("salt", "Stylistic Alternates"), ("swsh", "Swashes"), ("titl", "Titling Forms"),
    ]

    private func isOn(_ tag: String, in style: TextStyle) -> Bool {
        if let v = style.features?[tag] { return v != 0 }
        return Self.onByDefault.contains(tag)
    }

    private var featuresMenu: some View {
        let font = baseFont
        let offered = Fonts.features(of: font)
        let has = Set(offered.map(\.tag))
        let style = nodes.first?.style ?? TextStyle()
        let named = Self.known.filter { has.contains($0.tag) }
        let sets = offered.filter { $0.tag.hasPrefix("ss") && $0.tag.count == 4 }
        let variants = offered.filter { $0.tag.hasPrefix("cv") && $0.tag.count == 4 }
        let changed = (style.features ?? [:]).filter { has.contains($0.key) && ($0.value != 0) != Self.onByDefault.contains($0.key) }.count
        let title: LocalizedStringResource = named.isEmpty && sets.isEmpty && variants.isEmpty ? "No Features"
            : changed == 0 ? "Features" : "\(changed) Features"
        var entries = named.map { featureEntry($0.tag, $0.name, style: style) }
        if !sets.isEmpty {
            if !entries.isEmpty { entries.append(.separator) }
            entries += sets.map { featureEntry($0.tag, .verbatim($0.name), style: style) }
        }
        if !variants.isEmpty {
            if !entries.isEmpty { entries.append(.separator) }
            entries += variants.map { featureEntry($0.tag, .verbatim($0.name), style: style) }
        }
        if entries.isEmpty { entries = [.note("This font has no OpenType features to turn on.")] }
        let all = entries
        return MenuButton(id: "text-features", title: title, width: 260, fills: true) { all }
            .help("OpenType features of the font: figures, ligatures, stylistic sets")
    }

    /// A feature in the menu, ticked when it is on; pointing at it shows it turned the other way.
    private func featureEntry(_ tag: String, _ name: LocalizedStringResource, style: TextStyle) -> MenuEntry {
        let on = isOn(tag, in: style)
        let flip: (inout TextStyle) -> Void = { s in
            var f = s.features ?? [:]
            // Back to how the font sets it, rather than kept, where that is what is asked.
            if on == Self.onByDefault.contains(tag) { f[tag] = on ? 0 : 1 } else { f[tag] = nil }
            s.features = f.isEmpty ? nil : f
        }
        return MenuEntry.item(name, checked: on, preview: { p in previewStyle(p ? flip : nil) }) {
            set(on ? "Turn Feature Off" : "Turn Feature On", flip)
        }
    }

    // MARK: Variable fonts

    /// The axes the layers' font can be set along, when it is a variable font.
    private var axes: [Fonts.Axis] { Fonts.axes(of: baseFont) }

    /// The axes, folded under one line until opened or one is set: most text is in SF Pro, a
    /// variable font, and its axes are seldom wanted.
    private var axesBlock: some View {
        let open = showsAxes || common({ $0.axes != nil }) != false
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(LocalizedStringResource("text.axes", defaultValue: "Variable Font", comment: "Opens the axes a variable font can be set along, such as its weight and width."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                Spacer(minLength: 4)
                Text(verbatim: axes.map(\.name).joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                    .opacity(open ? 0 : 1)
                Chevron(color: Theme.ink3)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(Theme.unfold) { showsAxes.toggle() } }
            if open {
                ForEach(axes, id: \.tag) { axis in axisRow(axis) }
                    .transition(.unfold)
            }
        }
    }

    private func axisRow(_ axis: Fonts.Axis) -> some View {
        let font = baseFont
        let now = (CTFontCopyVariation(font) as? [NSNumber: NSNumber])?[NSNumber(value: Fonts.code(axis.tag))]?.doubleValue
        let value = common { $0.axes?[axis.tag] } ?? nil
        let decimals = axis.range.upperBound - axis.range.lowerBound > 20 ? 0 : 2
        return Row(title: .verbatim(axis.name)) {
            NumberField(label: "", value: value ?? now ?? axis.standard, range: axis.range,
                        scrub: (axis.range.upperBound - axis.range.lowerBound) / 300, decimals: decimals, action: "Change Font Axis") { v in
                set("Change Font Axis") { s in
                    var a = s.axes ?? [:]
                    a[axis.tag] = v
                    s.axes = a
                }
            }
        }
    }

    private func familyEntries(current: String?) -> [MenuEntry] {
        Fonts.families.map { f in
            // The family, in the face of it most like the one the letters have.
            let choose: (inout Letters) -> Void = { l in
                let face = Fonts.face(like: l.face, of: l.family, in: f)
                l.family = f
                l.face = face
            }
            return MenuEntry.item(.verbatim(Fonts.displayName(f)), checked: f == current,
                                  font: f != TextStyle.system && Fonts.showsOwnName(f) ? .custom(f, size: 13) : .system(size: 13),
                                  preview: { on in preview(on ? choose : nil) }) {
                restyle("Change Font", choose)
            }
        }
    }
}

/// A few symbol buttons in one well, each on or off by itself, such as underline and strikethrough.
struct IconToggles: View {
    /// Each one's symbol, what it is called, whether it is on, and what pressing it does.
    let options: [(String, LocalizedStringResource, Bool, () -> Void)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let (symbol, help, on, press) = option
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(on ? Theme.ink : Theme.ink2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.card)
                                .shadow(color: Theme.shadow.opacity(0.12), radius: 2, y: 1)
                                .transition(.opacity)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(Theme.spring) { press() } }
                    .help(Text(help))
                    .accessibilityLabel(Text(help))
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .well(radius: 8)
    }
}
