import SwiftUI
import AppKit

/// The design's named looks, while nothing is selected: its colours as paint chips, its type set
/// in itself, its shadows and corners on small cards. Pointing at one outlines every layer that has
/// it; a click opens it, to change it everywhere at once. Looks several layers have alike without a
/// name wait after them, dashed, each with how many have it: a click names it, and every one of
/// them with it. A design never needs setting up for any of this.
struct StyleKit: View {
    let store: DocumentStore
    /// The style opened to be changed, and whether its name is being typed.
    @State private var open: UUID?
    @State private var naming = false

    var body: some View {
        let found = store.styleShow.found(in: store)
        let uses = store.styleShow.uses(in: store)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(StyleKind.allCases, id: \.self) { kind in
                let named = store.styles(of: kind)
                let ghosts = Array((found[kind] ?? []).prefix(kind == .colour ? 8 : 4))
                if !named.isEmpty || !ghosts.isEmpty {
                    KitCard(store: store, kind: kind, named: named, ghosts: ghosts, uses: uses, open: $open, naming: $naming)
                        .transition(.card)
                }
            }
        }
        .padding(.horizontal, Inspector.gutter)
        .padding(.top, 14)
        .animation(Theme.unfold, value: store.doc.styles?.map(\.id))
        #if DEBUG
        // BEZZLE_STYLE_OPEN=name opens that style, for a test run to photograph it.
        .onAppear {
            if let name = ProcessInfo.processInfo.environment["BEZZLE_STYLE_OPEN"] { open = store.doc.styles?.first { $0.name == name }?.id }
        }
        #endif
        .onChange(of: store.doc.styles?.map(\.id)) { _, ids in
            if let open, !(ids ?? []).contains(open) { self.open = nil }
        }
    }
}

/// One kind of the design's styles, and the looks of that kind found without a name.
private struct KitCard: View {
    let store: DocumentStore
    let kind: StyleKind
    let named: [Style]
    let ghosts: [FoundLook]
    let uses: [UUID: Int]
    @Binding var open: UUID?
    @Binding var naming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch kind {
                case .text:
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(named) { style in
                            TypeRow(store: store, style: style, uses: uses[style.id] ?? 0, open: open == style.id) { toggle(style.id) }
                            if open == style.id { editor(style).transition(.unfold) }
                        }
                        ForEach(ghosts) { found in
                            GhostTypeRow(store: store, found: found) { name(found) }
                        }
                    }
                default:
                    let count = KitChip.columns(kind)
                    let columns = Array(repeating: GridItem(.fixed(KitChip.width(kind)), spacing: KitChip.gap), count: count)
                    VStack(alignment: .leading, spacing: 10) {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(named) { style in
                                KitChip(store: store, look: style.look, name: style.name, uses: uses[style.id] ?? 0, style: style.id,
                                        dark: store.hasDark ? style.look(dark: true) : nil,
                                        open: open == style.id) { toggle(style.id) }
                                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                            }
                            ForEach(ghosts) { found in
                                KitChip(store: store, look: found.look, name: nil, uses: found.count, found: found, open: false) { name(found) }
                                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                            }
                        }
                        if let id = open, let style = named.first(where: { $0.id == id }) {
                            editor(style).transition(.unfold)
                        }
                    }
                }
            }
            .padding(Inspector.cardInset)
        }
        .frame(width: Inspector.card, alignment: .leading)
        .card(radius: 12, lifted: open.map { id in named.contains { $0.id == id } } ?? false)
        .animation(Theme.unfold, value: open)
        .animation(Theme.pop, value: named.map(\.id))
        .animation(Theme.pop, value: ghosts.map(\.id))
    }

    private func toggle(_ id: UUID) {
        naming = false
        withAnimation(Theme.unfold) { open = open == id ? nil : id }
    }

    /// Names a look found on several layers, and opens the new style with its name ready to type.
    private func name(_ found: FoundLook) {
        store.styleShow.lit = []
        var made: UUID?
        withAnimation(Theme.pop) { made = store.name(found) }
        withAnimation(Theme.unfold) {
            open = made
            naming = true
        }
    }

    @ViewBuilder private func editor(_ style: Style) -> some View {
        StyleEditor(store: store, style: style, naming: $naming) { open = nil }
            .padding(.top, kind == .text ? 6 : 0)
            .padding(.bottom, kind == .text ? 8 : 0)
    }
}

// MARK: - Chips

/// A colour, shadow or corners of the design's. A colour is a paint chip, as a printer's fan
/// deck has them: the colour above, its name and hex on the strip below. Shadows and corners are
/// small cards with their names under them. Pointing at one lifts it and outlines every layer that
/// has it; dashed, it is a look found without a name, with how many layers have it.
private struct KitChip: View {
    static let gap: CGFloat = 8
    static func columns(_ kind: StyleKind) -> Int { kind == .colour ? 3 : 4 }
    static func width(_ kind: StyleKind) -> CGFloat {
        let n = CGFloat(columns(kind))
        return ((Inspector.content - gap * (n - 1)) / n).rounded(.down)
    }

    let store: DocumentStore
    let look: StyleLook
    /// Nil for a look found without one.
    let name: String?
    let uses: Int
    var style: UUID?
    var found: FoundLook?
    /// Its look in the dark, while the design shows anything dark: a colour then shows both.
    var dark: StyleLook? = nil
    let open: Bool
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        Group {
            if case .colour(let p) = look { paintChip(p) } else { tile }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(Theme.pop) { hovering = inside }
            point(inside)
        }
        .onTapGesture {
            point(false)
            tap()
        }
        .onDisappear { if hovering { point(false) } }
        .help(Text(verbatim: name ?? String(localized: "Give this look a name: all \(uses) layers that have it take it")))
        .accessibilityLabel(Text(verbatim: name ?? String(localized: "Unnamed look")))
        .accessibilityAddTraits(.isButton)
    }

    private var ghost: Bool { name == nil }
    private var width: CGFloat { Self.width(look.kind) }

    // MARK: A colour

    private func paintChip(_ p: ColourLook) -> some View {
        let chip = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                FillSwatch(fill: Fill(color: p.color, gradient: p.gradient), radius: 0)
                // The same colour in the dark, beside it, with the moon's mark.
                if let d = dark?.paint {
                    FillSwatch(fill: Fill(color: d.color, gradient: d.gradient), radius: 0)
                        .overlay(alignment: .bottomTrailing) {
                            MoonGlyph(size: 7)
                                .foregroundStyle(Color(nsColor: d.color.oklab.l > 0.6 ? .black : .white).opacity(0.55))
                                .padding(3)
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(height: 40)
            .animation(Theme.spring, value: dark != nil)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7, style: .continuous))
                .padding([.horizontal, .top], ghost ? 6 : 3)
            VStack(alignment: .leading, spacing: 1) {
                if let name {
                    Text(verbatim: name)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(open ? Theme.pencil : Theme.ink)
                    Text(verbatim: p.gradient != nil ? String(localized: "Gradient") : "#\(p.color.hex)")
                        .font(.system(size: 9, weight: .medium).monospaced())
                        .foregroundStyle(Theme.ink3)
                } else {
                    (hovering ? Text("Name it") : Text(verbatim: "×\(uses)"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(hovering ? Theme.ink : Theme.ink2)
                        .contentTransition(.opacity)
                    Text(verbatim: "#\(p.color.hex)")
                        .font(.system(size: 9, weight: .medium).monospaced())
                        .foregroundStyle(Theme.ink3)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, ghost ? 8 : 6)
            .padding(.top, 5)
            .padding(.bottom, 6)
        }
        .frame(width: width, alignment: .leading)
        .background {
            if ghost {
                chip.strokeBorder(Theme.ink.opacity(hovering ? 0.36 : 0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
            } else {
                chip.fill(Theme.paper)
                    .shadow(color: Theme.shadow.opacity(hovering ? 0.2 : 0.08), radius: hovering ? 9 : 2, y: hovering ? 5 : 1)
            }
        }
        .overlay {
            if !ghost {
                chip.strokeBorder(open ? Theme.pencil : Theme.hairline, lineWidth: open ? 1.5 : 0.5)
            }
        }
        .overlay(alignment: .topTrailing) { badge.offset(x: 5, y: -6) }
        .offset(y: hovering && !ghost ? -2 : 0)
        .rotation3DEffect(.degrees(hovering && !ghost ? 6 : 0), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.6)
        .scaleEffect(hovering ? 1.03 : 1, anchor: .bottom)
    }

    // MARK: A shadow or corners

    private var tile: some View {
        VStack(spacing: 5) {
            ZStack {
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                if ghost {
                    shape.strokeBorder(Theme.ink.opacity(hovering ? 0.38 : 0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
                } else {
                    shape.fill(Theme.well)
                        .overlay { shape.strokeBorder(Theme.pencil, lineWidth: open ? 2 : 0).padding(-3).opacity(open ? 1 : 0) }
                }
                picture
            }
            .frame(width: 46, height: 46)
            .overlay(alignment: .topTrailing) { badge.offset(x: 6, y: -5) }
            .scaleEffect(hovering ? 1.07 : 1)
            .offset(y: hovering ? -2 : 0)
            Group {
                if let name {
                    Text(verbatim: name).foregroundStyle(open ? Theme.pencil : Theme.ink2)
                } else {
                    Text("Name it").foregroundStyle(Theme.ink3).opacity(hovering ? 1 : 0)
                }
            }
            .font(.system(size: 10.5, weight: open ? .semibold : .regular))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: width)
        }
        .frame(width: width)
    }

    @ViewBuilder private var picture: some View {
        switch look {
        case .shadow(let s):
            let card = RoundedRectangle(cornerRadius: 4, style: .continuous)
            if s.inset == true {
                card.fill(Color.white.shadow(.inner(color: Color(nsColor: s.color.with(alpha: min(1, s.color.a * 3)).nsColor),
                                                    radius: min(max(0.8, s.blur / 3), 5), x: s.x / 3, y: min(s.y / 3, 3))))
                    .frame(width: 26, height: 22)
            } else {
                card.fill(Color.white)
                    .frame(width: 22, height: 18)
                    .shadow(color: Color(nsColor: s.color.with(alpha: min(1, s.color.a * 3)).nsColor),
                            radius: min(max(0.8, s.blur / 3.5), 7), x: s.x / 3, y: min(max(s.y / 3, 1), 6))
                    .offset(y: -3)
            }
        case .corners(let c):
            CornerMark(radius: c.radius, smooth: (c.smoothing ?? 0) > 0)
                .stroke(Theme.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 24, height: 24)
        case .text(let t):
            Text(verbatim: "Aa").font(StyleFont.font(t, size: 15)).foregroundStyle(Theme.ink)
        case .colour(let p):
            FillSwatch(fill: Fill(color: p.color, gradient: p.gradient), radius: 8).frame(width: 30, height: 30)
        }
    }

    /// How many layers have it: while pointed at, for a style; always, for a look found.
    @ViewBuilder private var badge: some View {
        if uses > 0, hovering, !ghost {
            Text(verbatim: "\(uses)")
                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.onInk)
                .padding(.horizontal, 4.5)
                .frame(minWidth: 15, minHeight: 15)
                .background { Capsule().fill(Theme.pencil) }
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        } else if ghost, look.kind != .colour {
            Text(verbatim: "×\(uses)")
                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 4.5)
                .frame(minHeight: 15)
                .background { Capsule().fill(Theme.card) }
                .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5) }
        }
    }

    private func point(_ inside: Bool) {
        if let style {
            store.styleShow.pointed = inside ? style : (store.styleShow.pointed == style ? nil : store.styleShow.pointed)
        } else if let found {
            store.styleShow.lit = inside ? Array(Set(found.uses.map(\.layer))) : []
        }
    }
}

/// One corner of a rectangle, as round as `radius` makes it, drawn from the left side up and
/// round to the top: how round the corners are, read at a glance.
private nonisolated struct CornerMark: Shape {
    let radius: CGFloat
    var smooth = false

    func path(in rect: CGRect) -> Path {
        // Shown not to scale but in order: a little rounding shows, a lot comes near a quarter circle.
        let r = min(rect.width, rect.height) * min(1, sqrt(max(radius, 0) / 40))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        if smooth {
            p.addCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                       control1: CGPoint(x: rect.minX, y: rect.minY + r * 0.25), control2: CGPoint(x: rect.minX + r * 0.25, y: rect.minY))
        } else {
            p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

/// A named type, set in itself, with its size beside it.
private struct TypeRow: View {
    let store: DocumentStore
    let style: Style
    let uses: Int
    let open: Bool
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        let t = style.look.type
        HStack(spacing: 8) {
            Text(verbatim: style.name)
                .font(t.map { StyleFont.font($0, size: min(max($0.size, 12), 22)) } ?? .system(size: 13))
                .foregroundStyle(open ? Theme.pencil : Theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if hovering, uses > 0 {
                Text(verbatim: "\(uses)")
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.onInk)
                    .padding(.horizontal, 4.5)
                    .frame(height: 15)
                    .background { Capsule().fill(Theme.pencil) }
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            Text(verbatim: t.map { SelectionInspector.said(Double($0.size)) } ?? "")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.ink3)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 32)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(open ? Theme.pencilWash : Theme.ink.opacity(hovering ? 0.05 : 0))
        }
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(Theme.quick) { hovering = inside }
            store.styleShow.pointed = inside ? style.id : (store.styleShow.pointed == style.id ? nil : store.styleShow.pointed)
        }
        .onTapGesture(perform: tap)
        .onDisappear { if hovering, store.styleShow.pointed == style.id { store.styleShow.pointed = nil } }
        .accessibilityLabel(Text(verbatim: style.name))
        .accessibilityAddTraits(.isButton)
    }
}

/// A type several text layers have alike without a name, dashed, set in itself.
private struct GhostTypeRow: View {
    let store: DocumentStore
    let found: FoundLook
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        let t = found.look.type
        HStack(spacing: 8) {
            Text(verbatim: t.map { "\(Fonts.displayName($0.family)) \($0.face)" } ?? "")
                .font(t.map { StyleFont.font($0, size: min(max($0.size, 12), 18)) } ?? .system(size: 13))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(verbatim: "×\(found.count)")
                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 4.5)
                .frame(height: 15)
                .background { Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5) }
            Text(verbatim: t.map { SelectionInspector.said(Double($0.size)) } ?? "")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.ink3)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 32)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.ink.opacity(hovering ? 0.34 : 0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
        }
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(Theme.quick) { hovering = inside }
            store.styleShow.lit = inside ? Array(Set(found.uses.map(\.layer))) : []
        }
        .onTapGesture {
            store.styleShow.lit = []
            tap()
        }
        .onDisappear { if hovering { store.styleShow.lit = [] } }
        .help(Text("Give this look a name: all \(found.count) layers that have it take it"))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Changing one

/// A style opened in the list: its name, and what makes its look. Every change goes to every layer
/// that has it, as they show at once.
private struct StyleEditor: View {
    @Environment(MenuHost.self) private var menus
    let store: DocumentStore
    let style: Style
    @Binding var naming: Bool
    let close: () -> Void
    @State private var draft = ""
    /// Whether its look in the dark is what is being changed.
    @State private var inTheDark = false
    @FocusState private var focused: Bool

    /// Colours and shadows have a look in the dark of their own.
    private var hasDarkLook: Bool { store.hasDark && (style.kind == .colour || style.kind == .shadow) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    NameMark()
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .focused($focused)
                        .onSubmit { commitName() }
                }
                .padding(.horizontal, 8)
                .frame(height: Theme.controlHeight)
                .well(radius: 7)
                RemoveButton(help: "Remove style") {
                    store.removeStyle(style.id)
                    close()
                }
            }
            if hasDarkLook {
                HStack(spacing: 8) {
                    LightDarkPair(dark: inTheDark) { d in inTheDark = d }
                    Spacer(minLength: 0)
                    if inTheDark, style.dark != nil {
                        CardButton(title: "Automatic", height: Theme.controlHeight) { store.followInTheDark(style.id) }
                            .help("Make it dark by itself again, from its light look")
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                .animation(Theme.spring, value: style.dark != nil)
            }
            look
        }
        .onAppear {
            draft = style.name
            if naming { DispatchQueue.main.async { focused = true } }
        }
        .onChange(of: style.name) { _, name in if !focused { draft = name } }
        .onChange(of: focused) { _, now in
            if !now {
                commitName()
                naming = false
            }
        }
    }

    private func commitName() {
        store.renameStyle(style.id, to: draft)
        if focused { StyleFocus.release(store) }
    }

    @ViewBuilder private var look: some View {
        let dark = hasDarkLook && inTheDark
        switch style.look(dark: dark) {
        case .colour(let p):
            if p.gradient == nil {
                ColorPanel(id: "style-\(style.id)", action: "Change Colour", start: p.color, key: "\(style.id)-\(dark)") { c in
                    store.changeStyle(style.id, "Change Colour", dark: dark) { $0 = .colour(ColourLook(color: c)) }
                }
                .padding(-14)
                .padding(.top, 4)
            } else {
                FillSwatch(fill: Fill(color: p.color, gradient: p.gradient), radius: 8)
                    .frame(height: 44)
            }
        case .text(let t):
            typeControls(t)
        case .shadow(let s):
            shadowControls(s)
        case .corners(let c):
            cornerControls(c)
        }
    }

    // MARK: Type

    @ViewBuilder private func typeControls(_ t: TypeLook) -> some View {
        MenuButton(id: "style-family-\(style.id)", title: .verbatim(Fonts.displayName(t.family)), width: Inspector.content, fills: true) {
            Fonts.families.map { f in
                MenuEntry.item(.verbatim(Fonts.displayName(f)), checked: f == t.family,
                               font: f != TextStyle.system && Fonts.showsOwnName(f) ? .custom(f, size: 13) : .system(size: 13)) {
                    type("Change Font") { $0.face = Fonts.face(like: $0.face, of: $0.family, in: f); $0.family = f }
                }
            }
        }
        HStack(spacing: 8) {
            MenuButton(id: "style-face-\(style.id)", title: .verbatim(t.face), width: 200, fills: true) {
                Fonts.faces(of: t.family).map { f in
                    MenuEntry.item(.verbatim(f), checked: f == t.face) { type("Change Font") { $0.face = f } }
                }
            }
            NumberField(label: "", value: Double(t.size), unit: "pt", range: 1...2000, scrub: 0.25, action: "Change Size") { v in
                type("Change Size") { $0.size = CGFloat(v) }
            }
            .frame(width: Inspector.endField)
        }
        Pair(NumberField(label: LocalizedStringResource("text.line-spacing", defaultValue: "Line", comment: "The distance between lines of text, beside the letter spacing."),
                         value: t.lineSpacing.map(Double.init), range: 0...4000, scrub: 0.25, action: "Change Line Spacing") { v in
                type("Change Line Spacing") { $0.lineSpacing = CGFloat(v) }
             },
             NumberField(label: "Letter", value: Double(t.tracking), range: -500...2000, scrub: 1, decimals: 0, action: "Change Letter Spacing") { v in
                type("Change Letter Spacing") { $0.tracking = CGFloat(v) }
             })
    }

    private func type(_ action: LocalizedStringResource, _ change: @escaping (inout TypeLook) -> Void) {
        store.changeStyle(style.id, action) { look in
            guard case .text(var t) = look else { return }
            change(&t)
            look = .text(t)
        }
    }

    // MARK: Shadow

    @ViewBuilder private func shadowControls(_ s: Shadow) -> some View {
        ColorField(id: "style-shadow-\(style.id)", color: s.color, action: "Change Shadow") { c in
            shadow("Change Shadow") { $0.color = c }
        }
        // As the shadow card has them.
        HStack(spacing: 8) {
            number("X", s.x, range: -1000...1000) { $0.x = $1 }
            number("Y", s.y, range: -1000...1000) { $0.y = $1 }
            number("B", s.blur, range: 0...1000) { $0.blur = $1 }
        }
        Row(title: LocalizedStringResource("shadow.spread", defaultValue: "Spread", comment: "How much bigger than its layer a shadow is cast, or smaller.")) {
            number("", s.spread ?? 0, range: -1000...1000) { $0.spread = $1 == 0 ? nil : $1 }
        }
    }

    private func number(_ label: LocalizedStringResource, _ value: CGFloat, range: ClosedRange<Double>,
                        _ set: @escaping (inout Shadow, CGFloat) -> Void) -> NumberField {
        NumberField(label: label, value: Double(value), range: range, scrub: 0.5, action: "Change Shadow") { v in
            shadow("Change Shadow") { set(&$0, CGFloat(v)) }
        }
    }

    private func shadow(_ action: LocalizedStringResource, _ change: @escaping (inout Shadow) -> Void) {
        store.changeStyle(style.id, action, dark: hasDarkLook && inTheDark) { look in
            guard case .shadow(var s) = look else { return }
            change(&s)
            look = .shadow(s)
        }
    }

    // MARK: Corners

    @ViewBuilder private func cornerControls(_ c: CornerLook) -> some View {
        HStack(spacing: 8) {
            SegmentedWell(selection: Binding(get: { (c.smoothing ?? 0) > 0 }, set: { on in
                corners(on ? "Smooth Corners" : "Round Corners") { $0.smoothing = on ? Presets.squircle : nil }
            }), options: [(false, "Round"), (true, "Squircle")])
            NumberField(label: "R", value: Double(c.radius), range: 0...10_000, action: "Change Corners") { v in
                corners("Change Corners") { $0.radius = CGFloat(v) }
            }
            .frame(width: Inspector.endField)
        }
    }

    private func corners(_ action: LocalizedStringResource, _ change: @escaping (inout CornerLook) -> Void) {
        store.changeStyle(style.id, action) { look in
            guard case .corners(var c) = look else { return }
            change(&c)
            look = .corners(c)
        }
    }
}

// MARK: - Worked out once per change

extension StyleShow {
    /// The looks found without a name, worked out once per change to the design.
    func found(in store: DocumentStore) -> [StyleKind: [FoundLook]] {
        // While a drag changes a style, the looks found stay as they were until it ends.
        if let worked = foundWorkedOut, worked.version == store.version || store.inGesture { return worked.found }
        let found = store.doc.foundLooks()
        foundWorkedOut = (store.version, found)
        return found
    }

    /// How many layers use each style, worked out once per change.
    func uses(in store: DocumentStore) -> [UUID: Int] {
        if let worked = usesWorkedOut, worked.version == store.version { return worked.uses }
        let uses = store.doc.styleUses
        usesWorkedOut = (store.version, uses)
        return uses
    }
}
