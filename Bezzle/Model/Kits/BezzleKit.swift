import Foundation
import CoreGraphics

private typealias P = Parts

/// Bezzle's own look, for designing web apps and sites: warm paper and near-black ink, wells
/// pressed into the paper where words are typed, cards lifted off it where things are clicked,
/// a serif for what is said out loud, and one colour besides: the blue pencil that marks where
/// you are, what has focus and how far along work is. Every action is ink.
nonisolated enum BezzleKit {
    static let kit = Kit(id: "bezzle", title: "Bezzle UI Kit", paper: .hex("#F0EDE7"), darkPaper: .hex("#1B1A18"), sections: [
        KitSection(title: "Navigation", components: [header, footer, sidebar, breadcrumbs, tabs, pagination, commandPalette]),
        KitSection(title: "Buttons", components: [primaryButton, secondaryButton, ghostButton, destructiveButton, iconButtonPart, buttonGroup]),
        KitSection(title: "Inputs", components: [textField, textFieldError, searchField, select, textarea, checkbox, radioGroup,
                                                 switches, slider, segmentedControl, datePicker]),
        KitSection(title: "Feedback", components: [toast, infoCallout, successCallout, warningCallout, tooltip, progress, badges, tags,
                                                   emptyState, skeleton]),
        KitSection(title: "Content", components: [hero, contentCard, statCard, pricingCard, avatars, avatarStack, table, modal, dropdownMenu]),
    ])

    // MARK: - Palette

    /// Paper, ink and pencil, light or dark, as Bezzle itself is drawn.
    nonisolated struct Palette {
        let dark: Bool
        var paper: RGBA { dark ? .hex("#1B1A18") : .hex("#F0EDE7") }
        var panel: RGBA { dark ? .hex("#22211F") : .hex("#F6F4EF") }
        var card: RGBA { dark ? .hex("#2A2926") : .hex("#FCFBF8") }
        var well: RGBA { dark ? .hex("#141312") : .hex("#E5E1D9") }
        var ink: RGBA { dark ? .hex("#EDEAE4") : .hex("#1C1B19") }
        var ink2: RGBA { ink.with(alpha: 0.64) }
        var ink3: RGBA { ink.with(alpha: 0.44) }
        var ink4: RGBA { ink.with(alpha: 0.22) }
        var hairline: RGBA { ink.with(alpha: 0.09) }
        /// The edge of a control, a little firmer than a hairline.
        var edge: RGBA { ink.with(alpha: dark ? 0.14 : 0.12) }
        /// A soft wash of ink: a count, a quiet chip.
        var tint: RGBA { ink.with(alpha: dark ? 0.08 : 0.055) }
        var shade: RGBA { dark ? .black : .hex("#3A3226") }
        var lip: RGBA { RGBA.white.with(alpha: dark ? 0.05 : 0.75) }
        /// Words on ink.
        var onInk: RGBA { dark ? .hex("#1B1A18") : .hex("#F6F4EF") }
        var pencil: RGBA { dark ? .hex("#8FA8F2") : .hex("#3559C7") }
        var red: RGBA { dark ? .hex("#E4705C") : .hex("#B3402F") }
        var green: RGBA { dark ? .hex("#7FBF96") : .hex("#3B7A55") }
        var amber: RGBA { dark ? .hex("#E3B062") : .hex("#99640F") }

        func wash(_ color: RGBA) -> RGBA { color.with(alpha: dark ? 0.16 : 0.10) }
        /// Ink for paper and paper for ink: a toast's or a tooltip's colours.
        var inverse: Palette { Palette(dark: !dark) }
        /// A warm shadow on paper, a deeper black one in the dark.
        func shadow(_ alpha: Double, y: CGFloat, blur: CGFloat) -> Shadow {
            P.shadow(y: y, blur: blur, shade.with(alpha: dark ? min(1, alpha * 3.2) : alpha))
        }

        /// The colours people are known by: clay, sage, sky, ochre and plum, a tint and its ink.
        func tone(_ i: Int) -> (RGBA, RGBA) {
            let light = [("#EBD3C4", "#7B4A32"), ("#D6E1D1", "#3E5D42"), ("#D5DDEF", "#34508F"), ("#EFDFBC", "#7A5714"), ("#E5D5E3", "#6B4466")]
            let dark = [("#4A3328", "#EDC6B2"), ("#2F3D2D", "#BFD7B9"), ("#2C3552", "#BACAF2"), ("#463A20", "#E8CF94"), ("#40303E", "#DFC0DA")]
            let pair = (self.dark ? dark : light)[i % light.count]
            return (.hex(pair.0), .hex(pair.1))
        }
    }

    /// The serif headings are set in: Iowan Old Style, else Charter or Georgia, else SF Pro.
    nonisolated enum Serif {
        static let family: String = ["Iowan Old Style", "Charter", "Georgia"].first { !Fonts.faces(of: $0).isEmpty } ?? TextStyle.system
        static let regular: String = face(["Roman", "Regular"], system: "Semibold")
        static let bold: String = face(["Bold"], system: "Bold")

        private static func face(_ wanted: [String], system: String) -> String {
            if family == TextStyle.system { return system }
            let faces = Fonts.faces(of: family)
            return wanted.first { faces.contains($0) } ?? faces.first ?? "Regular"
        }
    }

    // MARK: - Surfaces

    private static func inner(_ color: RGBA, y: CGFloat = 1, blur: CGFloat = 3) -> Shadow {
        Shadow(on: true, color: color, x: 0, y: y, blur: blur, inset: true, spread: nil)
    }

    nonisolated enum Lift { case rest, raised, floating }

    /// A card resting on the paper: lighter stock, a hairline edge and a soft warm shadow.
    private static func card(_ r: CGRect, _ c: Palette, radius: CGFloat = 14, lift: Lift = .rest) -> Node {
        card("Background", r, c, radius: radius, lift: lift)
    }

    private static func card(_ name: String, _ r: CGRect, _ c: Palette, radius: CGFloat = 14, lift: Lift = .rest) -> Node {
        var n = P.rect(name, r, c.card, radius: radius).outlined(c.hairline)
        switch lift {
        case .rest: n.shadows = [c.shadow(0.07, y: 1, blur: 2), c.shadow(0.06, y: 4, blur: 14)]
        case .raised: n.shadows = [c.shadow(0.08, y: 1, blur: 2), c.shadow(0.13, y: 10, blur: 28)]
        case .floating: n.shadows = [c.shadow(0.08, y: 1, blur: 3), c.shadow(0.2, y: 24, blur: 64)]
        }
        if c.dark { n.shadows.append(inner(.white.with(alpha: 0.05), y: 1, blur: 0)) }
        return n
    }

    /// Something to click: a small card with a firmer edge.
    private static func control(_ r: CGRect, _ c: Palette, radius: CGFloat = 10) -> Node {
        control("Background", r, c, radius: radius)
    }

    private static func control(_ name: String, _ r: CGRect, _ c: Palette, radius: CGFloat = 10) -> Node {
        var n = P.rect(name, r, c.card, radius: radius).outlined(c.edge)
        n.shadows = [c.shadow(0.08, y: 1, blur: 2), c.shadow(0.05, y: 2, blur: 6)]
        if c.dark { n.shadows.append(inner(.white.with(alpha: 0.06), y: 1, blur: 0)) }
        return n
    }

    /// Somewhere to type: a well pressed into the paper, shaded along its top, a light lip below.
    private static func well(_ r: CGRect, _ c: Palette, radius: CGFloat = 10) -> Node {
        well("Field", r, c, radius: radius)
    }

    /// `firm` for the small ones, a box or a track, whose edge has to show in the dark too.
    private static func well(_ name: String, _ r: CGRect, _ c: Palette, radius: CGFloat = 10, firm: Bool = false) -> Node {
        let rim = firm ? (c.dark ? 0.16 : 0.08) : (c.dark ? 0.08 : 0.05)
        var n = P.rect(name, r, c.well, radius: radius).outlined(c.ink.with(alpha: rim))
        n.shadows = [P.shadow(y: 1, blur: 0, c.lip), inner(c.shade.with(alpha: c.dark ? 0.7 : 0.2), y: 1, blur: 3)]
        return n
    }

    /// A field that has focus: lifted out of its well, ringed in pencil.
    private static func focused(_ r: CGRect, _ c: Palette, radius: CGFloat = 10, color: RGBA? = nil) -> Node {
        let k = color ?? c.pencil
        var n = P.rect("Field", r, c.card, radius: radius).outlined(k, width: 1.5)
        n.shadows = [P.shadow(y: 0, blur: 0, k.with(alpha: c.dark ? 0.28 : 0.18), spread: 3)]
        return n
    }

    private static func vertical(_ n: Node, _ top: RGBA, _ bottom: RGBA) -> Node {
        var n = n
        n.fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: top), GradientStop(offset: 1, color: bottom)],
                                   start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1))
        return n
    }

    // MARK: - Words and icons

    /// Words on one line, their middle at `cy`; `x` is where they start, or their middle or end.
    private static func words(_ s: String, x: CGFloat, cy: CGFloat, size: CGFloat, weight: String = "Regular", color: RGBA,
                              family: String = TextStyle.system, align: TextAlign = .left, tracking: CGFloat = 0, name: String? = nil) -> Node {
        P.text(s, name: name, in: P.box(x, cy - 20, 0, 40), size: size, weight: weight, color: color, family: family, align: align, tracking: tracking)
    }

    private static func width(_ s: String, _ size: CGFloat, _ weight: String = "Regular", family: String = TextStyle.system) -> CGFloat {
        P.width(of: s, size: size, weight: weight, family: family)
    }

    /// A Lucide icon, its middle at `cx`, `cy`, drawn in lines a little lighter than the set's own.
    private static func icon(_ name: String, _ cx: CGFloat, _ cy: CGFloat, _ size: CGFloat = 16, _ color: RGBA, weight: CGFloat? = nil) -> Node {
        P.icon(name, .lucide, center: CGPoint(x: cx, y: cy), size: size, color, weight: weight ?? (size >= 20 ? 1.5 : 1.75))
    }

    /// A key on a keyboard, as a shortcut is shown: a small card with a firm lower edge.
    private static func key(_ s: String, x: CGFloat, cy: CGFloat, _ c: Palette, height: CGFloat = 20) -> Node {
        let kw = max(height, ceil(width(s, 11, "Medium") + 10))
        var cap = P.rect("Key", P.box(x, cy - height / 2, kw, height), c.card, radius: 5).outlined(c.edge)
        cap.shadows = [P.shadow(y: 1, blur: 0, c.ink.with(alpha: c.dark ? 0.3 : 0.1))]
        return P.group("Shortcut", [cap, words(s, x: x + kw / 2, cy: cy, size: 11, weight: "Medium", color: c.ink2, align: .center, name: "Label")])
    }

    /// Shortcut keys side by side, ending at `right`.
    private static func keys(_ list: [String], right: CGFloat, cy: CGFloat, _ c: Palette) -> Node {
        var made: [Node] = []
        var x: CGFloat = 0
        for k in list {
            let n = key(k, x: x, cy: cy, c)
            made.append(n)
            x = n.frame.maxX + 4
        }
        let g = P.group("Shortcut", made)
        return g.moved(right - g.frame.maxX, 0)
    }

    // MARK: - Buttons

    nonisolated enum Kind { case primary, secondary, ghost, destructive }

    /// A button as wide as its words and icon with room either side, or `width` wide with them in the middle.
    private static func button(_ title: String, _ kind: Kind, _ c: Palette, icon: String? = nil, trailing: Bool = false,
                               x: CGFloat = 0, y: CGFloat = 0, height h: CGFloat = 40, width fixed: CGFloat? = nil, name: String? = nil) -> Node {
        let size: CGFloat = h >= 44 ? 15 : h >= 36 ? 14 : 13
        let face = kind == .primary || kind == .destructive ? "Semibold" : "Medium"
        let iconSize: CGFloat = h >= 36 ? 16 : 15
        let gap: CGFloat = h >= 36 ? 8 : 6
        let pad: CGFloat = h >= 44 ? 22 : h >= 40 ? 18 : h >= 36 ? 15 : 12
        let tw = width(title, size, face)
        let content = tw + (icon == nil ? 0 : iconSize + gap)
        let bw = fixed ?? ceil(content + pad * 2 - (icon == nil ? 0 : 2))
        let r = P.box(x, y, bw, h)
        let fg: RGBA
        var made: [Node] = []
        switch kind {
        case .primary:
            fg = c.onInk
            var bg = vertical(P.rect("Background", r, c.ink, radius: h / 4), c.dark ? .hex("#F8F6F2") : .hex("#2F2D29"), c.ink)
            bg.shadows = [c.shadow(0.24, y: 1, blur: 2), c.shadow(0.14, y: 4, blur: 10), inner(.white.with(alpha: c.dark ? 0.7 : 0.13), y: 1, blur: 0)]
            made.append(bg)
        case .destructive:
            fg = c.dark ? c.onInk : .hex("#FFF8F4")
            var bg = vertical(P.rect("Background", r, c.red, radius: h / 4), c.dark ? .hex("#EA8371") : .hex("#C24D3A"), c.red)
            bg.shadows = [P.shadow(y: 1, blur: 2, c.red.with(alpha: c.dark ? 0.4 : 0.3)), P.shadow(y: 4, blur: 10, c.red.with(alpha: 0.2)),
                          inner(.white.with(alpha: c.dark ? 0.4 : 0.16), y: 1, blur: 0)]
            made.append(bg)
        case .secondary:
            fg = c.ink
            made.append(control(r, c, radius: h / 4))
        case .ghost:
            fg = c.ink
            made.append(P.frame(bw, h, x: x, y: y))
        }
        let nudge: CGFloat = icon == nil ? 0 : trailing ? 1 : -1
        var cx = x + ((bw - content) / 2 + nudge).rounded()
        let cy = y + h / 2
        let iconColor = kind == .secondary || kind == .ghost ? c.ink2 : fg
        if let icon, !trailing {
            made.append(self.icon(icon, cx + iconSize / 2, cy, iconSize, iconColor))
            cx += iconSize + gap
        }
        made.append(words(title, x: cx, cy: cy, size: size, weight: face, color: fg, name: "Label"))
        if let icon, trailing { made.append(self.icon(icon, cx + tw + gap + iconSize / 2, cy, iconSize, iconColor)) }
        let names: [Kind: String] = [.primary: "Primary Button", .secondary: "Secondary Button", .ghost: "Ghost Button", .destructive: "Destructive Button"]
        return P.group(name ?? names[kind]!, made)
    }

    /// A square button holding one icon.
    private static func iconButton(_ name: String, x: CGFloat, y: CGFloat, size s: CGFloat = 40, _ c: Palette) -> Node {
        P.group("Icon Button", [control(P.box(x, y, s, s), c, radius: s / 4), icon(name, x + s / 2, y + s / 2, s >= 40 ? 18 : 16, c.ink)])
    }

    /// A part as big as what `make` lays out, measured with the words of the language it is made in.
    private static func hugging(_ id: String, _ title: LocalizedStringResource, _ make: @escaping @Sendable (KitLook) -> Node) -> Component {
        Component(id: id, title: title, size: make(KitLook(width: 0)).frame.size, make: make)
    }

    static let primaryButton = hugging("bezzle.primary-button", "Primary Button") { look in
        P.part([button(String(localized: "Continue"), .primary, Palette(dark: look.dark), icon: "arrow-right", trailing: true)])
    }

    static let secondaryButton = hugging("bezzle.secondary-button", "Secondary Button") { look in
        P.part([button(String(localized: "Preview"), .secondary, Palette(dark: look.dark), icon: "eye")])
    }

    static let ghostButton = hugging("bezzle.ghost-button", "Ghost Button") { look in
        P.part([button(String(localized: "Learn more"), .ghost, Palette(dark: look.dark), icon: "arrow-right", trailing: true)])
    }

    static let destructiveButton = hugging("bezzle.destructive-button", "Destructive Button") { look in
        P.part([button(String(localized: "Delete"), .destructive, Palette(dark: look.dark), icon: "trash")])
    }

    static let iconButtonPart = Component(id: "bezzle.icon-button", title: "Icon Button", size: CGSize(width: 40, height: 40)) { look in
        P.part([iconButton("sliders-horizontal", x: 0, y: 0, Palette(dark: look.dark))])
    }

    static let buttonGroup = hugging("bezzle.button-group", "Button Group") { look in
        let c = Palette(dark: look.dark)
        let items = [("pencil-line", String(localized: "Edit")), ("copy", String(localized: "Duplicate")), ("archive", String(localized: "Archive"))]
        var x: CGFloat = 0
        var segments: [Node] = [], rules: [Node] = []
        for (i, (name, title)) in items.enumerated() {
            let tw = width(title, 14, "Medium")
            let sw = ceil(tw + 16 + 8 + 30)
            if i > 0 { rules.append(P.rect("Divider", P.box(x, 0, 1, 40), c.edge)) }
            segments.append(P.group(title, [
                P.frame(sw, 40, x: x),
                icon(name, x + 15 + 8, 20, 16, c.ink2),
                words(title, x: x + 15 + 24, cy: 20, size: 14, weight: "Medium", color: c.ink, name: "Label"),
            ]))
            x += sw
        }
        return P.part([control(P.box(0, 0, x, 40), c)] + rules + segments)
    }

    // MARK: - Navigation

    /// The sample brand: a leaf on ink and its name in the serif.
    private static func logo(x: CGFloat, cy: CGFloat, _ c: Palette, size s: CGFloat = 28) -> Node {
        P.group("Logo", [
            P.rect("Mark", P.box(x, cy - s / 2, s, s), c.ink, radius: s * 0.3),
            icon("leaf", x + s / 2, cy, s * 0.57, c.onInk, weight: 1.9),
            words("Linden", x: x + s + 10, cy: cy - 1, size: s * 0.72, weight: Serif.bold, color: c.ink, family: Serif.family, tracking: -10, name: "Name"),
        ])
    }

    /// How far in from the sides a page's content lies: 1200 wide in the middle, or near the edges when narrower.
    private static func gutter(_ w: CGFloat) -> CGFloat {
        w < 720 ? 20 : max(32, ((w - 1200) / 2).rounded())
    }

    static let header = Component(id: "bezzle.header", title: "Header", size: CGSize(width: 1440, height: 72), fit: .top, minWidth: 360) { look in
        let c = Palette(dark: look.dark), w = look.width
        let pad = gutter(w)
        let brand = logo(x: pad, cy: 36, c)
        var made: [Node] = [
            P.frame(w, 72),
            P.rect("Background", P.box(0, 0, w, 72), c.paper).frosted(24, tint: 0.86),
            P.rule(x: 0, y: 71, width: w, c.hairline, thickness: 1),
            brand,
        ]
        if w < 720 {
            made.append(iconButton("menu", x: w - pad - 40, y: 16, c))
            return P.part(made)
        }
        let cta = button(String(localized: "Get started"), .primary, c, height: 36)
        let placedCTA = cta.moved(w - pad - cta.frame.width, 18)
        let signIn = button(String(localized: "Sign in"), .ghost, c, height: 36)
        let placedSignIn = signIn.moved(placedCTA.frame.minX - 4 - signIn.frame.width, 18)
        let links: [(String, Bool, Bool)] = [(String(localized: "Product"), false, false), (String(localized: "Solutions"), true, false),
                                             (String(localized: "Pricing"), false, true), (String(localized: "Customers"), false, false),
                                             (String(localized: "Docs"), false, false)]
        var x = brand.frame.maxX + 52
        var items: [Node] = []
        for (title, menu, current) in links {
            let tw = width(title, 14, "Medium")
            let lw = tw + (menu ? 18 : 0)
            if x + lw > placedSignIn.frame.minX - 24 { break }
            var link = [words(title, x: x, cy: 36, size: 14, weight: "Medium", color: current ? c.ink : c.ink2, name: "Label")]
            if menu { link.append(icon("chevron-down", x + tw + 9, 37, 14, c.ink3)) }
            if current { link.append(P.circle("Current", center: CGPoint(x: x + tw / 2, y: 53), radius: 2, c.pencil)) }
            items.append(P.group(title, link))
            x += lw + 30
        }
        made += [P.group("Links", items), P.group("Actions", [placedSignIn, placedCTA])]
        return P.part(made)
    }

    static let footer = Component(id: "bezzle.footer", title: "Footer", size: CGSize(width: 1440, height: 356), fit: .bottom, minWidth: 360) { look in
        let c = Palette(dark: look.dark), w = look.width
        let narrow = w < 720
        let pad = gutter(w)
        let columns: [(String, [String])] = [
            (String(localized: "Product"), [String(localized: "Features"), String(localized: "Pricing"), String(localized: "Changelog"), String(localized: "Roadmap")]),
            (String(localized: "Company"), [String(localized: "About"), String(localized: "Careers"), String(localized: "Journal"), String(localized: "Contact")]),
            (String(localized: "Resources"), [String(localized: "Docs"), String(localized: "Tutorials"), String(localized: "Community"), String(localized: "Support")]),
        ]
        var made: [Node] = [P.rule(x: 0, y: 0, width: w, c.hairline, thickness: 1)]

        // The brand, what it is for, and the letter it sends.
        let top: CGFloat = narrow ? 40 : 64
        let blurbWidth = narrow ? w - pad * 2 : 280
        let blurb = P.paragraph(String(localized: "Tools for teams who care about the small things."), name: "Tagline", x: pad, y: top + 44,
                                width: blurbWidth, size: 15, color: c.ink2, line: 23)
        let letterY = blurb.frame.maxY + 28
        let fieldWidth = narrow ? w - pad * 2 - 48 : 232
        var send = vertical(P.rect("Background", P.box(pad + fieldWidth + 8, letterY + 24, 40, 40), c.ink, radius: 10),
                            c.dark ? .hex("#F8F6F2") : .hex("#2F2D29"), c.ink)
        send.shadows = [c.shadow(0.22, y: 1, blur: 2), inner(.white.with(alpha: c.dark ? 0.7 : 0.13), y: 1, blur: 0)]
        made.append(P.group("Brand", [
            logo(x: pad, cy: top + 14, c),
            blurb,
            P.group("Newsletter", [
                words(String(localized: "The monthly letter"), x: pad, cy: letterY + 8, size: 13, weight: "Semibold", color: c.ink, name: "Label"),
                well(P.box(pad, letterY + 24, fieldWidth, 40), c),
                words("you@company.com", x: pad + 14, cy: letterY + 44, size: 14, color: c.ink3, name: "Placeholder"),
                P.group("Subscribe", [send, icon("arrow-right", pad + fieldWidth + 28, letterY + 44, 16, c.onInk)]),
            ]),
        ]))

        // Where else to go, in columns.
        let columnsTop = narrow ? letterY + 24 + 40 + 40 : top
        let columnWidth = narrow ? ((w - pad * 2) / 3).rounded(.down) : min(180, ((w - pad * 2 - 360) / 3).rounded(.down))
        let columnsLeft = narrow ? pad : w - pad - columnWidth * 3
        var lists: [Node] = []
        for (i, (title, links)) in columns.enumerated() {
            let x = columnsLeft + CGFloat(i) * columnWidth
            var list = [words(title, x: x, cy: columnsTop + 8, size: 13, weight: "Semibold", color: c.ink, name: "Title")]
            for (j, link) in links.enumerated() {
                list.append(words(link, x: x, cy: columnsTop + 44 + CGFloat(j) * 32, size: 14, color: c.ink2))
            }
            lists.append(P.group(title, list))
        }
        made.append(P.group("Links", lists))

        // The fine print, and whether all is well.
        let ruleY = narrow ? columnsTop + 44 + 3 * 32 + 40 : max(letterY + 64, columnsTop + 44 + 3 * 32) + 48
        made.append(P.rule(x: pad, y: ruleY, width: w - pad * 2, c.hairline, thickness: 1))
        let statusWords = String(localized: "All systems normal")
        let statusWidth = ceil(width(statusWords, 13, "Medium") + 42)
        func status(x: CGFloat, cy: CGFloat) -> Node {
            P.group("Status", [
                P.pill("Background", P.box(x, cy - 14, statusWidth, 28), c.tint),
                P.circle("Glow", center: CGPoint(x: x + 16, y: cy), radius: 6, c.green.with(alpha: 0.18)),
                P.circle("Light", center: CGPoint(x: x + 16, y: cy), radius: 3.5, c.green),
                words(statusWords, x: x + 29, cy: cy, size: 13, weight: "Medium", color: c.ink2, name: "Label"),
            ])
        }
        let copyright = "© 2026 Linden Labs"
        let legal = [String(localized: "Privacy"), String(localized: "Terms")]
        var fine: [Node] = []
        let bottom: CGFloat
        if narrow {
            fine.append(status(x: pad, cy: ruleY + 36))
            let cy = ruleY + 80
            fine.append(words(copyright, x: pad, cy: cy, size: 13, color: c.ink3, name: "Copyright"))
            var x = w - pad
            for word in legal.reversed() {
                fine.append(words(word, x: x, cy: cy, size: 13, color: c.ink2, align: .right))
                x -= width(word, 13) + 20
            }
            bottom = cy + 36
        } else {
            let cy = ruleY + 32
            fine.append(words(copyright, x: pad, cy: cy, size: 13, color: c.ink3, name: "Copyright"))
            var x = w - pad - statusWidth
            fine.append(status(x: x, cy: cy))
            x -= 28
            for word in legal.reversed() {
                fine.append(words(word, x: x, cy: cy, size: 13, color: c.ink2, align: .right))
                x -= width(word, 13) + 24
            }
            bottom = cy + 32
        }
        made.append(P.group("Fine Print", fine))
        return P.part([P.frame(w, bottom), P.rect("Background", P.box(0, 0, w, bottom), c.panel)] + made)
    }

    static let sidebar = Component(id: "bezzle.sidebar", title: "Sidebar", size: CGSize(width: 264, height: 720)) { look in
        let c = Palette(dark: look.dark)
        let (markTint, markInk) = c.tone(0)
        var made: [Node] = [
            P.rect("Background", P.box(0, 0, 264, 720), c.panel),
            P.rect("Edge", P.box(263, 0, 1, 720), c.hairline),
            P.group("Workspace", [
                P.rect("Mark", P.box(16, 18, 32, 32), markTint, radius: 9),
                words("L", x: 32, cy: 34, size: 17, weight: Serif.bold, color: markInk, family: Serif.family, align: .center, name: "Initial"),
                words("Linden Studio", x: 58, cy: 26, size: 14, weight: "Semibold", color: c.ink, name: "Name"),
                words(String(localized: "Pro plan"), x: 58, cy: 43, size: 12, color: c.ink3, name: "Plan"),
                icon("chevrons-up-down", 238, 34, 16, c.ink3),
            ]),
            P.group("Search", [
                well(P.box(16, 66, 232, 36), c, radius: 9),
                icon("search", 34, 84, 16, c.ink3),
                words(String(localized: "Search"), x: 50, cy: 84, size: 14, color: c.ink3, name: "Placeholder"),
                keys(["⌘", "K"], right: 240, cy: 84, c),
            ]),
        ]
        let items: [(String, String, String?)] = [("house", String(localized: "Home"), nil), ("inbox", String(localized: "Inbox"), "4"),
                                                  ("folder-kanban", String(localized: "Projects"), nil), ("calendar", String(localized: "Calendar"), nil),
                                                  ("chart-line", String(localized: "Reports"), nil)]
        var nav: [Node] = []
        for (i, (name, title, count)) in items.enumerated() {
            let y = 122 + CGFloat(i) * 38, cy = y + 18
            let on = i == 2
            var item: [Node] = []
            if on { item.append(card("Selection", P.box(10, y, 244, 36), c, radius: 9)) }
            item.append(icon(name, 34, cy, 18, on ? c.pencil : c.ink2))
            item.append(words(title, x: 54, cy: cy, size: 14, weight: "Medium", color: on ? c.ink : c.ink2, name: "Label"))
            if let count {
                item.append(P.pill("Count", P.box(222, cy - 10, 22, 20), c.tint))
                item.append(words(count, x: 233, cy: cy, size: 12, weight: "Semibold", color: c.ink2, align: .center, name: "Number"))
            }
            nav.append(P.group(title, item))
        }
        made.append(P.group("Pages", nav))

        let teams: [(String, RGBA)] = [(String(localized: "Design"), c.pencil), (String(localized: "Research"), c.green), (String(localized: "Marketing"), c.amber)]
        var team: [Node] = [
            words(String(localized: "Teams"), x: 22, cy: 340, size: 12, weight: "Medium", color: c.ink3, name: "Title"),
            icon("plus", 238, 340, 16, c.ink3),
        ]
        for (i, (title, color)) in teams.enumerated() {
            let cy = 374 + CGFloat(i) * 38
            team.append(P.group(title, [
                P.rect("Colour", P.box(29, cy - 5, 10, 10), color, radius: 3),
                words(title, x: 54, cy: cy, size: 14, weight: "Medium", color: c.ink2, name: "Label"),
            ]))
        }
        made.append(P.group("Teams", team))

        made.append(P.group("Storage", [
            card(P.box(16, 568, 232, 76), c, radius: 12),
            words(String(localized: "Storage"), x: 30, cy: 590, size: 13, weight: "Semibold", color: c.ink, name: "Title"),
            words("7.2 / 10 GB", x: 234, cy: 590, size: 12, color: c.ink3, align: .right, name: "Amount"),
            well("Track", P.box(30, 608, 204, 6), c, radius: 3, firm: true),
            P.rect("Used", P.box(30, 608, 147, 6), c.pencil, radius: 3),
            words(String(localized: "Upgrade plan"), x: 30, cy: 629, size: 12, weight: "Semibold", color: c.pencil, name: "Link"),
        ]))

        made.append(P.group("Account", [
            P.rule(x: 16, y: 660, width: 232, c.hairline, thickness: 1),
            avatar("AL", x: 16, y: 674, size: 32, tone: 2, c),
            words("Ada Lark", x: 58, cy: 681, size: 14, weight: "Medium", color: c.ink, name: "Name"),
            words("ada@linden.studio", x: 58, cy: 698, size: 12, color: c.ink3, name: "Email"),
            icon("settings", 238, 690, 18, c.ink3),
        ]))
        return P.part(made)
    }

    static let breadcrumbs = hugging("bezzle.breadcrumbs", "Breadcrumbs") { look in
        let c = Palette(dark: look.dark)
        let trail = [String(localized: "Projects"), "Linden Website", String(localized: "Homepage")]
        var made: [Node] = [P.frame(16, 24), icon("house", 8, 12, 16, c.ink3)]
        var x: CGFloat = 16
        for (i, step) in trail.enumerated() {
            made.append(icon("chevron-right", x + 14, 12, 14, c.ink4))
            x += 28
            let last = i == trail.count - 1
            made.append(words(step, x: x, cy: 12, size: 14, weight: last ? "Medium" : "Regular", color: last ? c.ink : c.ink2))
            x += width(step, 14, last ? "Medium" : "Regular")
        }
        return P.part(made)
    }

    static let tabs = Component(id: "bezzle.tabs", title: "Tabs", size: CGSize(width: 560, height: 44)) { look in
        let c = Palette(dark: look.dark)
        let items: [(String, String?)] = [(String(localized: "Overview"), nil), (String(localized: "Activity"), nil),
                                          (String(localized: "Members"), "12"), (String(localized: "Settings"), nil)]
        var made: [Node] = [P.frame(560, 44), P.rule(x: 0, y: 43, width: 560, c.hairline, thickness: 1)]
        var x: CGFloat = 0
        for (i, (title, count)) in items.enumerated() {
            let on = i == 0
            let tw = width(title, 14, "Medium")
            var tab = [words(title, x: x, cy: 20, size: 14, weight: "Medium", color: on ? c.ink : c.ink2, name: "Label")]
            var end = x + tw
            if let count {
                let cw = ceil(width(count, 12, "Semibold") + 12)
                tab.append(P.pill("Count", P.box(end + 6, 11, cw, 18), c.tint))
                tab.append(words(count, x: end + 6 + cw / 2, cy: 20, size: 12, weight: "Semibold", color: c.ink2, align: .center, name: "Number"))
                end += 6 + cw
            }
            if on { tab.append(P.rect("Indicator", P.box(x, 42, end - x, 2), c.pencil, radius: 1)) }
            made.append(P.group(title, tab))
            x = end + 32
        }
        return P.part(made)
    }

    static let pagination = hugging("bezzle.pagination", "Pagination") { look in
        let c = Palette(dark: look.dark)
        let previous = button(String(localized: "Previous"), .ghost, c, icon: "chevron-left", height: 36)
        var made: [Node] = [previous]
        var x = previous.frame.maxX + 12
        for page in ["1", "2", "3", "4", "5", "…", "12"] {
            let on = page == "3"
            var item: [Node] = [on ? control("Selection", P.box(x, 0, 36, 36), c, radius: 9) : P.frame(36, 36, x: x)]
            item.append(words(page, x: x + 18, cy: 18, size: 14, weight: on ? "Semibold" : "Medium", color: on ? c.ink : c.ink2, align: .center, name: "Number"))
            made.append(P.group("Page \(page)", item))
            x += 40
        }
        made.append(button(String(localized: "Next"), .ghost, c, icon: "chevron-right", trailing: true, x: x + 8, height: 36))
        return P.part(made)
    }

    static let commandPalette = hugging("bezzle.command-palette", "Command Palette") { look in
        let c = Palette(dark: look.dark), w: CGFloat = 600
        let query = String(localized: "new")
        var made: [Node] = [
            P.group("Search", [
                icon("search", 28, 30, 20, c.ink3),
                words(query, x: 52, cy: 30, size: 17, color: c.ink, name: "Query"),
                P.rect("Caret", P.box(52 + width(query, 17) + 2, 19, 1.5, 22), c.pencil, radius: 0.75),
                keys(["esc"], right: w - 20, cy: 30, c),
            ]),
            P.rule(x: 0, y: 60, width: w, c.hairline, thickness: 1),
        ]
        let groups: [(String, [(String, String, String?, [String])])] = [
            (String(localized: "Suggestions"), [("folder-plus", String(localized: "New project"), nil, ["⌘", "N"]),
                                                ("file-plus", String(localized: "New page"), nil, ["⌘", "P"]),
                                                ("user-plus", String(localized: "Invite people"), nil, ["⌘", "I"])]),
            (String(localized: "Pages"), [("sparkles", String(localized: "What's new"), String(localized: "Changelog"), []),
                                          ("bell", String(localized: "Newsletter settings"), String(localized: "Settings"), [])]),
        ]
        var y: CGFloat = 68
        var first = true
        for (title, rows) in groups {
            var list = [words(title, x: 20, cy: y + 14, size: 12, weight: "Medium", color: c.ink3, name: "Title")]
            y += 28
            for (name, label, place, shortcut) in rows {
                let cy = y + 22
                var row: [Node] = []
                if first { row.append(P.rect("Highlight", P.box(8, y, w - 16, 44), c.wash(c.pencil), radius: 9)) }
                row.append(P.rect("Icon Well", P.box(16, cy - 14, 28, 28), first ? c.card : c.tint, radius: 7))
                row.append(icon(name, 30, cy, 16, first ? c.pencil : c.ink2))
                row.append(words(label, x: 56, cy: cy, size: 14, weight: "Medium", color: c.ink, name: "Label"))
                if let place {
                    row.append(words(place, x: 56 + width(label, 14, "Medium") + 8, cy: cy, size: 13, color: c.ink3, name: "Place"))
                }
                if !shortcut.isEmpty { row.append(keys(shortcut, right: w - 20, cy: cy, c)) }
                if first { row.append(icon("corner-down-left", w - 20 - 52 - 14, cy, 15, c.pencil)) }
                list.append(P.group(label, row))
                first = false
                y += 44
            }
            made.append(P.group(title, list))
            y += 8
        }
        let footY = y + 4
        var hints: [Node] = []
        var x: CGFloat = 20
        for (caps, label) in [(["↑", "↓"], String(localized: "Navigate")), (["↵"], String(localized: "Open")), (["esc"], String(localized: "Close"))] {
            for cap in caps {
                let k = key(cap, x: x, cy: footY + 22, c)
                hints.append(k)
                x = k.frame.maxX + 4
            }
            hints.append(words(label, x: x + 2, cy: footY + 22, size: 12, color: c.ink3))
            x += width(label, 12) + 20
        }
        let foot = P.group("Footer", [
            P.rect("Background", P.box(1, footY, w - 2, 43), c.panel, corners: [0, 0, 13, 13]),
            P.rule(x: 0, y: footY, width: w, c.hairline, thickness: 1),
        ] + hints)
        return P.part([card(P.box(0, 0, w, footY + 44), c, lift: .floating)] + made + [foot])
    }

    // MARK: - Inputs

    /// A field's name over it.
    private static func label(_ s: String, x: CGFloat = 0, _ c: Palette) -> Node {
        words(s, x: x, cy: 8, size: 13, weight: "Medium", color: c.ink, name: "Label")
    }

    static let textField = Component(id: "bezzle.text-field", title: "Text Field", size: CGSize(width: 320, height: 88)) { look in
        let c = Palette(dark: look.dark)
        return P.part([
            label(String(localized: "Work email"), c),
            P.group("Input", [
                well(P.box(0, 24, 320, 40), c),
                icon("mail", 22, 44, 16, c.ink3),
                words("name@company.com", x: 40, cy: 44, size: 14, color: c.ink3, name: "Placeholder"),
            ]),
            words(String(localized: "We only use it to send receipts."), x: 0, cy: 80, size: 12.5, color: c.ink3, name: "Hint"),
        ])
    }

    static let textFieldError = Component(id: "bezzle.text-field-error", title: "Text Field with Error", size: CGSize(width: 320, height: 88)) { look in
        let c = Palette(dark: look.dark)
        var field = well(P.box(0, 24, 320, 40), c)
        field.border = P.border(c.red, width: 1.5)
        return P.part([
            label(String(localized: "Password"), c),
            words(String(localized: "Forgot?"), x: 320, cy: 8, size: 13, weight: "Medium", color: c.pencil, align: .right, name: "Link"),
            P.group("Input", [
                field,
                words("••••••••", x: 14, cy: 44, size: 17, color: c.ink, tracking: 60, name: "Value"),
                icon("eye-off", 298, 44, 16, c.ink3),
            ]),
            P.group("Error", [
                icon("circle-alert", 7, 80, 14, c.red),
                words(String(localized: "Use at least 8 characters."), x: 20, cy: 80, size: 12.5, weight: "Medium", color: c.red, name: "Message"),
            ]),
        ])
    }

    static let searchField = Component(id: "bezzle.search-field", title: "Search Field", size: CGSize(width: 320, height: 40)) { look in
        let c = Palette(dark: look.dark)
        return P.part([
            well(P.box(0, 0, 320, 40), c),
            icon("search", 22, 20, 16, c.ink3),
            words(String(localized: "Search projects"), x: 40, cy: 20, size: 14, color: c.ink3, name: "Placeholder"),
            keys(["⌘", "K"], right: 310, cy: 20, c),
        ])
    }

    static let select = Component(id: "bezzle.select", title: "Select", size: CGSize(width: 240, height: 64)) { look in
        let c = Palette(dark: look.dark)
        return P.part([
            label(String(localized: "Role"), c),
            P.group("Menu", [
                control(P.box(0, 24, 240, 40), c),
                icon("user-round", 22, 44, 16, c.ink2),
                words(String(localized: "Editor"), x: 40, cy: 44, size: 14, color: c.ink, name: "Value"),
                icon("chevrons-up-down", 218, 44, 16, c.ink3),
            ]),
        ])
    }

    static let textarea = hugging("bezzle.textarea", "Textarea") { look in
        let c = Palette(dark: look.dark)
        let text = P.paragraph(String(localized: "The new pricing page reads well. Could the plan table stay in view while I scroll?"),
                               name: "Value", x: 14, y: 36, width: 292, size: 14, color: c.ink, line: 21)
        let bottom = max(136, text.frame.maxY + 34)
        return P.part([
            label(String(localized: "Feedback"), c),
            words("86 / 500", x: 320, cy: 8, size: 12, color: c.ink3, align: .right, name: "Count"),
            P.group("Input", [
                focused(P.box(0, 24, 320, bottom - 24), c),
                text,
                P.line("Grip", from: CGPoint(x: 312, y: bottom - 12), to: CGPoint(x: 304, y: bottom - 4), c.ink4, width: 1.25),
                P.line("Grip", from: CGPoint(x: 312, y: bottom - 7), to: CGPoint(x: 309, y: bottom - 4), c.ink4, width: 1.25),
            ]),
        ])
    }

    /// A small box, ticked or empty.
    private static func box(on: Bool, x: CGFloat, y: CGFloat, _ c: Palette, mixed: Bool = false) -> Node {
        if on || mixed {
            var b = vertical(P.rect("Box", P.box(x, y, 18, 18), c.ink, radius: 5), c.dark ? .hex("#F8F6F2") : .hex("#34312D"), c.ink)
            b.shadows = [c.shadow(0.2, y: 1, blur: 2)]
            return P.group("Checkbox", [b, icon(mixed ? "minus" : "check", x + 9, y + 9, 14, c.onInk, weight: 2.6)])
        }
        return P.group("Checkbox", [well("Box", P.box(x, y, 18, 18), c, radius: 5, firm: true)])
    }

    static let checkbox = Component(id: "bezzle.checkbox", title: "Checkbox", size: CGSize(width: 320, height: 92)) { look in
        let c = Palette(dark: look.dark)
        let rows = [(true, String(localized: "Email me about new features"), String(localized: "A short note, once a month.")),
                    (false, String(localized: "Share anonymous usage data"), String(localized: "Helps us find and fix problems."))]
        var made: [Node] = [P.frame(320, 92)]
        for (i, (on, title, detail)) in rows.enumerated() {
            let y = CGFloat(i) * 54
            made.append(P.group(title, [
                box(on: on, x: 0, y: y + 1, c),
                words(title, x: 30, cy: y + 10, size: 14, weight: "Medium", color: c.ink, name: "Label"),
                words(detail, x: 30, cy: y + 29, size: 13, color: c.ink3, name: "Description"),
            ]))
        }
        return P.part(made)
    }

    static let radioGroup = hugging("bezzle.radio-group", "Radio Group") { look in
        let c = Palette(dark: look.dark)
        var made: [Node] = [label(String(localized: "Who can comment"), c)]
        let options = [String(localized: "Anyone with the link"), String(localized: "Only collaborators"), String(localized: "No one")]
        for (i, option) in options.enumerated() {
            let cy = 40 + CGFloat(i) * 32
            let on = i == 1
            let dot: [Node]
            if on {
                var ring = vertical(P.oval("Circle", P.box(0, cy - 9, 18, 18), c.ink), c.dark ? .hex("#F8F6F2") : .hex("#34312D"), c.ink)
                ring.shadows = [c.shadow(0.2, y: 1, blur: 2)]
                dot = [ring, P.circle("Dot", center: CGPoint(x: 9, y: cy), radius: 3.5, c.onInk)]
            } else {
                var hollow = P.oval("Circle", P.box(0, cy - 9, 18, 18), c.well).outlined(c.ink.with(alpha: c.dark ? 0.16 : 0.08))
                hollow.shadows = [P.shadow(y: 1, blur: 0, c.lip), inner(c.shade.with(alpha: c.dark ? 0.7 : 0.2), y: 1, blur: 3)]
                dot = [hollow]
            }
            made.append(P.group(option, [P.group("Radio", dot), words(option, x: 30, cy: cy, size: 14, weight: on ? "Medium" : "Regular", color: c.ink, name: "Label")]))
        }
        return P.part(made)
    }

    /// An on and off switch: a knob in a well, which fills with ink when on.
    private static func toggle(on: Bool, x: CGFloat, y: CGFloat, _ c: Palette) -> Node {
        var knob = P.oval("Knob", P.box(on ? x + 18 : x + 2, y + 2, 20, 20), on ? c.onInk : c.dark ? .hex("#3D3B38") : c.card)
        knob.shadows = [c.shadow(0.25, y: 1, blur: 2), c.shadow(0.08, y: 2, blur: 4)]
        if on {
            var track = vertical(P.pill("Track", P.box(x, y, 40, 24), c.ink), c.dark ? .hex("#F8F6F2") : .hex("#34312D"), c.ink)
            track.shadows = [inner(.black.with(alpha: c.dark ? 0.12 : 0.3), y: 1, blur: 2)]
            return P.group("Switch", [track, knob])
        }
        return P.group("Switch", [well("Track", P.box(x, y, 40, 24), c, radius: 12, firm: true), knob.outlined(c.edge)])
    }

    static let switches = Component(id: "bezzle.switch", title: "Switch", size: CGSize(width: 320, height: 102)) { look in
        let c = Palette(dark: look.dark)
        let rows = [(true, String(localized: "Autosave"), String(localized: "Keep every change as you type")),
                    (false, String(localized: "Snap to grid"), String(localized: "Align layers to the nearest guide"))]
        var made: [Node] = [P.frame(320, 102), P.rule(x: 0, y: 51, width: 320, c.hairline, thickness: 1)]
        for (i, (on, title, detail)) in rows.enumerated() {
            let y = CGFloat(i) * 64
            made.append(P.group(title, [
                words(title, x: 0, cy: y + 10, size: 14, weight: "Medium", color: c.ink, name: "Label"),
                words(detail, x: 0, cy: y + 29, size: 13, color: c.ink3, name: "Description"),
                toggle(on: on, x: 280, y: y + 7, c),
            ]))
        }
        return P.part(made)
    }

    static let slider = Component(id: "bezzle.slider", title: "Slider", size: CGSize(width: 300, height: 76)) { look in
        let c = Palette(dark: look.dark)
        let at: CGFloat = 300 * 0.375
        var thumb = P.oval("Thumb", P.box(at - 11, 33, 22, 22), c.card).outlined(c.edge)
        thumb.shadows = [c.shadow(0.2, y: 1, blur: 2), c.shadow(0.1, y: 3, blur: 8)]
        return P.part([
            words(String(localized: "Corner radius"), x: 0, cy: 10, size: 13, weight: "Medium", color: c.ink, name: "Label"),
            P.group("Value", [
                well(P.box(244, 0, 56, 22), c, radius: 6),
                words("12 px", x: 272, cy: 11, size: 12, weight: "Medium", color: c.ink2, align: .center, name: "Number"),
            ]),
            P.group("Slider", [
                well("Track", P.box(0, 41, 300, 6), c, radius: 3, firm: true),
                P.rect("Fill", P.box(0, 41, at, 6), c.pencil, radius: 3),
                thumb,
                P.circle("Grip", center: CGPoint(x: at, y: 44), radius: 2.5, c.pencil),
            ]),
            words("0", x: 0, cy: 68, size: 12, color: c.ink3, name: "Least"),
            words("32", x: 300, cy: 68, size: 12, color: c.ink3, align: .right, name: "Most"),
        ])
    }

    static let segmentedControl = hugging("bezzle.segmented-control", "Segmented Control") { look in
        let c = Palette(dark: look.dark)
        let options = [String(localized: "Day"), String(localized: "Week"), String(localized: "Month"), String(localized: "Year")]
        let sw = ceil(options.map { width($0, 13, "Medium") }.max()! + 36)
        var made: [Node] = [well(P.box(0, 0, sw * CGFloat(options.count) + 6, 36), c, radius: 10)]
        for (i, option) in options.enumerated() {
            let x = 3 + CGFloat(i) * sw
            let on = i == 1
            var segment: [Node] = []
            if on {
                var thumb = P.rect("Thumb", P.box(x, 3, sw, 30), c.card, radius: 8).outlined(c.hairline)
                thumb.shadows = [c.shadow(0.12, y: 1, blur: 2), c.shadow(0.06, y: 2, blur: 6)]
                segment.append(thumb)
            }
            segment.append(words(option, x: x + sw / 2, cy: 18, size: 13, weight: "Medium", color: on ? c.ink : c.ink2, align: .center, name: "Label"))
            made.append(P.group(option, segment))
        }
        return P.part(made)
    }

    static let datePicker = hugging("bezzle.date-picker", "Date Picker") { look in
        let c = Palette(dark: look.dark), w: CGFloat = 300
        let cal: Calendar = {
            var cal = Calendar(identifier: .gregorian)
            cal.locale = .current
            cal.timeZone = TimeZone(identifier: "UTC") ?? .current
            return cal
        }()
        func day(_ d: Int, month: Int = 11) -> Date { cal.date(from: DateComponents(year: 2026, month: month, day: d)) ?? Date() }
        let format = DateFormatter()
        format.locale = .current
        format.timeZone = cal.timeZone
        format.setLocalizedDateFormatFromTemplate("MMMdyyyy")
        let chosen = format.string(from: day(12))
        format.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        let month = format.string(from: day(1))

        var made: [Node] = [
            label(String(localized: "Start date"), c),
            P.group("Input", [
                focused(P.box(0, 24, w, 40), c),
                icon("calendar", 22, 44, 16, c.ink2),
                words(chosen, x: 40, cy: 44, size: 14, color: c.ink, name: "Value"),
                icon("chevron-down", w - 22, 44, 16, c.ink3),
            ]),
        ]
        let top: CGFloat = 76
        let first = cal.firstWeekday
        let symbols = cal.shortStandaloneWeekdaySymbols
        let offset = (cal.component(.weekday, from: day(1)) - first + 7) % 7
        let rows = (offset + 30 + 6) / 7
        let colW: CGFloat = 38, left = (w - colW * 7) / 2
        let gridTop = top + 80
        let height = gridTop + CGFloat(rows) * 36 + 10 - top
        var grid: [Node] = [
            card(P.box(0, top, w, height), c, lift: .raised),
            words(month, x: 18, cy: top + 28, size: 16, weight: Serif.bold, color: c.ink, family: Serif.family, name: "Month"),
            P.group("Previous", [P.frame(28, 28, x: w - 76, y: top + 14), icon("chevron-left", w - 62, top + 28, 16, c.ink2)]),
            P.group("Next", [P.frame(28, 28, x: w - 44, y: top + 14), icon("chevron-right", w - 30, top + 28, 16, c.ink2)]),
        ]
        var weekdays: [Node] = []
        for i in 0..<7 {
            let s = String(symbols[(first - 1 + i) % 7].prefix(2))
            weekdays.append(words(s, x: left + colW * (CGFloat(i) + 0.5), cy: top + 64, size: 12, weight: "Medium", color: c.ink3, align: .center))
        }
        grid.append(P.group("Weekdays", weekdays))
        var days: [Node] = []
        for cell in 0..<(rows * 7) {
            let n = cell - offset + 1
            let inMonth = n >= 1 && n <= 30
            let shown = inMonth ? n : n < 1 ? 31 + n : n - 30
            let cx = left + colW * (CGFloat(cell % 7) + 0.5), cy = gridTop + CGFloat(cell / 7) * 36 + 18
            let chosenDay = inMonth && n == 12, today = inMonth && n == 4
            var cellNodes: [Node] = []
            if chosenDay {
                var dot = vertical(P.circle("Selection", center: CGPoint(x: cx, y: cy), radius: 16, c.ink), c.dark ? .hex("#F8F6F2") : .hex("#34312D"), c.ink)
                dot.shadows = [c.shadow(0.2, y: 1, blur: 3)]
                cellNodes.append(dot)
            }
            let color = chosenDay ? c.onInk : today ? c.pencil : inMonth ? c.ink : c.ink4
            cellNodes.append(words("\(shown)", x: cx, cy: cy, size: 14, weight: chosenDay || today ? "Semibold" : "Regular", color: color, align: .center, name: "Number"))
            if today { cellNodes.append(P.circle("Today", center: CGPoint(x: cx, y: cy + 11), radius: 1.75, c.pencil)) }
            days.append(cellNodes.count == 1 ? cellNodes[0].named("\(shown)") : P.group("\(shown)", cellNodes))
        }
        grid.append(P.group("Days", days))
        made.append(P.group("Calendar", grid))
        return P.part(made)
    }

    // MARK: - Feedback

    static let toast = Component(id: "bezzle.toast", title: "Toast", size: CGSize(width: 380, height: 64)) { look in
        let c = Palette(dark: look.dark), i = c.inverse
        var bg = P.rect("Background", P.box(0, 0, 380, 64), c.ink, radius: 12)
        bg.shadows = [c.shadow(0.14, y: 2, blur: 4), c.shadow(0.18, y: 12, blur: 32), inner(.white.with(alpha: c.dark ? 0.6 : 0.08), y: 1, blur: 0)]
        return P.part([
            bg,
            icon("circle-check", 28, 32, 20, i.green),
            words(String(localized: "Page published"), x: 50, cy: 23, size: 14, weight: "Semibold", color: i.ink, name: "Title"),
            words("linden.studio/pricing", x: 50, cy: 42, size: 13, color: i.ink2, name: "Detail"),
            words(String(localized: "Undo"), x: 318, cy: 32, size: 13, weight: "Semibold", color: i.pencil, align: .right, name: "Action"),
            P.rect("Divider", P.box(332, 20, 1, 24), i.hairline),
            icon("x", 356, 32, 16, i.ink3),
        ])
    }

    /// A note set apart in a colour: a title, what it means, and what to do about it.
    private static func callout(_ c: Palette, color: RGBA, icon name: String, title: String, body: String, action: String? = nil) -> Node {
        let w: CGFloat = 420
        let text = P.paragraph(body, name: "Message", x: 44, y: 38, width: w - 44 - 20, size: 14, color: c.ink2, line: 21)
        var made: [Node] = [
            icon(name, 25, 25, 18, color),
            words(title, x: 44, cy: 25, size: 14, weight: "Semibold", color: c.ink, name: "Title"),
            text,
        ]
        var bottom = text.frame.maxY
        if let action {
            made.append(words(action, x: 44, cy: bottom + 20, size: 13, weight: "Semibold", color: color, name: "Action"))
            made.append(icon("arrow-right", 44 + width(action, 13, "Semibold") + 12, bottom + 20, 14, color))
            bottom += 30
        }
        var bg = P.rect("Background", P.box(0, 0, w, bottom + 16), c.card, radius: 12).outlined(color.with(alpha: c.dark ? 0.24 : 0.2))
        bg.fills = [Fill(color: c.card), Fill(color: color.with(alpha: c.dark ? 0.12 : 0.09))]
        return P.part([bg] + made)
    }

    static let infoCallout = hugging("bezzle.info-callout", "Info Callout") { look in
        let c = Palette(dark: look.dark)
        return callout(c, color: c.pencil, icon: "info", title: String(localized: "Your trial ends in 5 days"),
                       body: String(localized: "Add a payment method to keep your projects and everyone you invited."),
                       action: String(localized: "Add payment method"))
    }

    static let successCallout = hugging("bezzle.success-callout", "Success Callout") { look in
        let c = Palette(dark: look.dark)
        return callout(c, color: c.green, icon: "circle-check", title: String(localized: "Domain connected"),
                       body: String(localized: "linden.studio now points to your site and is served securely."))
    }

    static let warningCallout = hugging("bezzle.warning-callout", "Warning Callout") { look in
        let c = Palette(dark: look.dark)
        return callout(c, color: c.amber, icon: "triangle-alert", title: String(localized: "Storage almost full"),
                       body: String(localized: "You have used 92% of your space. Free some up or upgrade your plan."))
    }

    static let tooltip = hugging("bezzle.tooltip", "Tooltip") { look in
        let c = Palette(dark: look.dark), i = c.inverse
        let title = String(localized: "Copy link")
        let tw = width(title, 13, "Medium"), kw = width("⌘C", 12, "Medium")
        let w = ceil(12 + tw + 10 + kw + 12)
        var bubble = P.rect("Background", P.box(0, 0, w, 32), c.ink, radius: 8)
        bubble.shadows = [c.shadow(0.16, y: 2, blur: 6)]
        var tip = P.shape("Arrow", "M0 0H14L8.4 5.6Q7 7 5.6 5.6Z", box: P.box(0, 0, 14, 7), in: P.box(w / 2 - 7, 32, 14, 7), c.ink)
        tip.shadows = [c.shadow(0.1, y: 2, blur: 3)]
        return P.part([
            tip, bubble,
            words(title, x: 12, cy: 16, size: 13, weight: "Medium", color: i.ink, name: "Label"),
            words("⌘C", x: w - 12, cy: 16, size: 12, weight: "Medium", color: i.ink3, align: .right, name: "Shortcut"),
        ])
    }

    static let progress = Component(id: "bezzle.progress", title: "Progress", size: CGSize(width: 360, height: 64)) { look in
        let c = Palette(dark: look.dark)
        let done: CGFloat = 360 * 0.64
        var fill = vertical(P.rect("Fill", P.box(0, 28, done, 8), c.pencil, radius: 4), c.pencil.with(alpha: 0.85), c.pencil)
        fill.shadows = [inner(.white.with(alpha: c.dark ? 0.25 : 0.3), y: 1, blur: 0)]
        return P.part([
            P.frame(360, 64),
            words(String(localized: "Uploading 3 files"), x: 0, cy: 10, size: 14, weight: "Medium", color: c.ink, name: "Label"),
            words("64%", x: 360, cy: 10, size: 14, weight: "Medium", color: c.ink2, align: .right, name: "Amount"),
            P.group("Bar", [well("Track", P.box(0, 28, 360, 8), c, radius: 4, firm: true), fill]),
            words("2.4 MB / 3.8 MB", x: 0, cy: 57, size: 12, color: c.ink3, name: "Detail"),
            words(String(localized: "About a minute left"), x: 360, cy: 57, size: 12, color: c.ink3, align: .right, name: "Time"),
        ])
    }

    /// A small word in a pill of its colour, with a light when `dot`.
    private static func badge(_ s: String, color: RGBA?, dot: Bool = false, x: CGFloat, y: CGFloat, _ c: Palette) -> Node {
        let tw = width(s, 12, "Medium")
        let bw = ceil(tw + 20 + (dot ? 12 : 0))
        let fg = color ?? c.ink2
        var made = [P.pill("Background", P.box(x, y, bw, 24), color.map(c.wash) ?? c.tint)]
        if dot { made.append(P.circle("Light", center: CGPoint(x: x + 13, y: y + 12), radius: 3, fg)) }
        made.append(words(s, x: x + 10 + (dot ? 12 : 0), cy: y + 12, size: 12, weight: "Medium", color: fg, name: "Label"))
        return P.group(s, made)
    }

    static let badges = hugging("bezzle.badges", "Badges") { look in
        let c = Palette(dark: look.dark)
        let list: [(String, RGBA?, Bool)] = [(String(localized: "New"), c.pencil, false), (String(localized: "Active"), c.green, true),
                                             (String(localized: "Pending"), c.amber, true), (String(localized: "Failed"), c.red, true),
                                             (String(localized: "Draft"), nil, false)]
        var made: [Node] = []
        var x: CGFloat = 0
        for (s, color, dot) in list {
            let b = badge(s, color: color, dot: dot, x: x, y: 0, c)
            made.append(b)
            x = b.frame.maxX + 8
        }
        return P.part(made)
    }

    static let tags = hugging("bezzle.tags", "Tags") { look in
        let c = Palette(dark: look.dark)
        let list: [(String, RGBA)] = [(String(localized: "Design"), c.pencil), (String(localized: "Research"), c.green), ("Q4", c.amber)]
        var made: [Node] = []
        var x: CGFloat = 0
        for (s, color) in list {
            let tw = width(s, 13, "Medium")
            let tagW = ceil(10 + 8 + 8 + tw + 6 + 14 + 8)
            made.append(P.group(s, [
                control(P.box(x, 0, tagW, 32), c, radius: 8),
                P.circle("Colour", center: CGPoint(x: x + 14, y: 16), radius: 4, color),
                words(s, x: x + 26, cy: 16, size: 13, weight: "Medium", color: c.ink, name: "Label"),
                icon("x", x + tagW - 15, 16, 14, c.ink3),
            ]))
            x += tagW + 8
        }
        let add = String(localized: "Add tag")
        let addW = ceil(10 + 14 + 6 + width(add, 13, "Medium") + 12)
        var outline = P.rect("Outline", P.box(x, 0, addW, 32), c.ink, radius: 8)
        outline.fill.on = false
        outline.border = Border(on: true, color: c.ink.with(alpha: 0.24), width: 1, position: .inside, dash: 4, gap: 3)
        made.append(P.group(add, [outline, icon("plus", x + 17, 16, 14, c.ink2), words(add, x: x + 30, cy: 16, size: 13, weight: "Medium", color: c.ink2, name: "Label")]))
        return P.part(made)
    }

    static let emptyState = hugging("bezzle.empty-state", "Empty State") { look in
        let c = Palette(dark: look.dark), w: CGFloat = 440
        let body = P.paragraph(String(localized: "Projects keep your pages, pictures and notes together. Start one from scratch or bring in a file."),
                               name: "Message", x: 60, y: 172, width: 320, size: 14, color: c.ink2, align: .center, line: 21)
        let primary = button(String(localized: "New project"), .primary, c, icon: "plus", y: body.frame.maxY + 24)
        let secondary = button(String(localized: "Import"), .secondary, c, icon: "upload", y: body.frame.maxY + 24)
        let both = primary.frame.width + 10 + secondary.frame.width
        let left = ((w - both) / 2).rounded()
        let bottom = primary.frame.maxY + 40
        var outline = P.rect("Outline", P.box(0, 0, w, bottom), c.ink, radius: 14)
        outline.fill.on = false
        outline.border = Border(on: true, color: c.ink.with(alpha: 0.2), width: 1, position: .inside, dash: 6, gap: 4)
        var badge = P.circle("Badge", center: CGPoint(x: w / 2 + 27, y: 101), radius: 13, c.card).outlined(c.hairline)
        badge.shadows = [c.shadow(0.12, y: 1, blur: 3)]
        return P.part([
            outline,
            P.group("Picture", [
                well("Hollow", P.box(w / 2 - 38, 40, 76, 76), c, radius: 38),
                icon("folder-open", w / 2, 78, 30, c.ink3),
                badge,
                icon("plus", w / 2 + 27, 101, 14, c.pencil, weight: 2.2),
            ]),
            words(String(localized: "No projects yet"), x: w / 2, cy: 152, size: 22, weight: Serif.regular, color: c.ink, family: Serif.family, align: .center, name: "Title"),
            body,
            P.group("Actions", [secondary.moved(left, 0), primary.moved(left + secondary.frame.width + 10, 0)]),
        ])
    }

    static let skeleton = Component(id: "bezzle.skeleton", title: "Skeleton", size: CGSize(width: 360, height: 132)) { look in
        let c = Palette(dark: look.dark)
        let bone = c.dark ? RGBA.hex("#3A3935") : RGBA.hex("#ECE8E1")
        func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Node {
            P.rect("Line", P.box(x, y, w, h), bone, radius: h / 2)
        }
        return P.part([
            card(P.box(0, 0, 360, 132), c),
            P.oval("Avatar", P.box(20, 20, 40, 40), bone),
            bar(72, 26, 136, 10), bar(72, 44, 84, 8),
            P.rect("Badge", P.box(284, 26, 56, 20), bone, radius: 10),
            bar(20, 80, 320, 8), bar(20, 96, 292, 8), bar(20, 112, 188, 8),
        ])
    }

    // MARK: - Content

    static let hero = hugging("bezzle.hero", "Hero") { look in
        let c = Palette(dark: look.dark)
        let eyebrow = String(localized: "New: shared libraries")
        let ew = ceil(12 + 14 + 6 + width(eyebrow, 13, "Medium") + 12)
        let title = P.paragraph(String(localized: "Make work that feels made by hand."), name: "Title", x: 0, y: 52, width: 620,
                                size: 56, weight: Serif.regular, color: c.ink, family: Serif.family, line: 60, tracking: -18)
        let body = P.paragraph(String(localized: "Linden is the calm workspace for design teams: pages, pictures and feedback in one place."),
                               name: "Subtitle", x: 0, y: title.frame.maxY + 20, width: 500, size: 18, color: c.ink2, line: 28)
        let y = body.frame.maxY + 36
        let primary = button(String(localized: "Get started"), .primary, c, icon: "arrow-right", trailing: true, y: y, height: 44)
        let secondary = button(String(localized: "Book a demo"), .secondary, c, x: primary.frame.maxX + 12, y: y, height: 44)
        return P.part([
            P.group("Eyebrow", [
                P.pill("Background", P.box(0, 0, ew, 28), c.wash(c.pencil)),
                icon("sparkles", 19, 14, 14, c.pencil),
                words(eyebrow, x: 32, cy: 14, size: 13, weight: "Medium", color: c.pencil, name: "Label"),
            ]),
            title, body,
            P.group("Actions", [primary, secondary]),
        ])
    }

    /// A painted placeholder: a low sun over two hills, in the paper's own colours.
    private static func picture(_ r: CGRect, _ c: Palette, radius: CGFloat) -> Node {
        let sky = vertical(P.rect("Sky", r, .white, radius: radius), c.dark ? .hex("#2B2723") : .hex("#EADBC6"), c.dark ? .hex("#4D3F31") : .hex("#F4EBDD"))
        let box = P.box(0, 0, 320, 180)
        func hill(_ name: String, _ d: String, _ color: RGBA) -> Node { P.shape(name, d, box: box, in: r, color) }
        var g = P.group("Picture", [
            sky,
            P.circle("Sun", center: CGPoint(x: r.minX + r.width * 0.68, y: r.minY + r.height * 0.42), radius: r.height * 0.15,
                     c.dark ? .hex("#C9945E") : .hex("#E9A66C")),
            hill("Far Hill", "M0 118C46 96 92 88 146 104C196 119 248 92 320 98V180H0Z", c.dark ? .hex("#4B4236") : .hex("#CDB79A")),
            hill("Near Hill", "M0 146C58 126 118 124 176 140C230 155 276 140 320 132V180H0Z", c.dark ? .hex("#5C4F3F") : .hex("#A98E6D")),
        ])
        g.clipsToFirst = true
        return g
    }

    static let contentCard = hugging("bezzle.card", "Card") { look in
        let c = Palette(dark: look.dark), w: CGFloat = 320
        let kind = String(localized: "Guide")
        let title = P.paragraph(String(localized: "Designing with paper and ink"), name: "Title", x: 20, y: 222, width: 280,
                                size: 21, weight: Serif.regular, color: c.ink, family: Serif.family, line: 26, tracking: -6)
        let body = P.paragraph(String(localized: "How warm neutrals, soft depth and one honest accent make an interface feel considered."),
                               name: "Summary", x: 20, y: title.frame.maxY + 8, width: 280, size: 14, color: c.ink2, line: 21)
        let footY = body.frame.maxY + 20
        let read = String(localized: "Read")
        return P.part([
            card(P.box(0, 0, w, footY + 52), c),
            picture(P.box(8, 8, w - 16, 180), c, radius: 8),
            P.group("Meta", [
                words(kind, x: 20, cy: 208, size: 12, weight: "Semibold", color: c.pencil, name: "Kind"),
                words(String(localized: "6 min read"), x: 20 + width(kind, 12, "Semibold") + 10, cy: 208, size: 12, color: c.ink3, name: "Length"),
            ]),
            title, body,
            P.rule(x: 20, y: footY, width: w - 40, c.hairline, thickness: 1),
            P.group("Author", [
                avatar("AL", x: 20, y: footY + 14, size: 24, tone: 2, c),
                words("Ada Lark", x: 52, cy: footY + 26, size: 13, weight: "Medium", color: c.ink, name: "Name"),
            ]),
            P.group("Action", [
                words(read, x: w - 40, cy: footY + 26, size: 13, weight: "Semibold", color: c.ink, align: .right, name: "Label"),
                icon("arrow-right", w - 28, footY + 26, 14, c.ink),
            ]),
        ])
    }

    /// A smooth line through values, as SVG path data in a box `w` by `h`.
    private static func spark(_ values: [CGFloat], w: CGFloat, h: CGFloat, closed: Bool) -> String {
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let pts = values.enumerated().map { i, v in
            CGPoint(x: w * CGFloat(i) / CGFloat(values.count - 1), y: 2 + (h - 4) * (1 - (v - lo) / max(hi - lo, 1)))
        }
        func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
        var d = "M\(f(pts[0].x)) \(f(pts[0].y))"
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            let a = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let b = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            d += "C\(f(a.x)) \(f(a.y)) \(f(b.x)) \(f(b.y)) \(f(p2.x)) \(f(p2.y))"
        }
        if closed { d += "L\(f(w)) \(f(h))L0 \(f(h))Z" }
        return d
    }

    static let statCard = Component(id: "bezzle.stat-card", title: "Stat Card", size: CGSize(width: 300, height: 176)) { look in
        let c = Palette(dark: look.dark)
        let values: [CGFloat] = [18, 22, 20, 27, 25, 31, 29, 34, 33, 40, 37, 45]
        let area = P.box(20, 116, 260, 40), box = P.box(0, 0, 260, 40)
        var fill = P.shape("Area", spark(values, w: 260, h: 40, closed: true), box: box, in: area, c.pencil)
        fill.fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: c.pencil.with(alpha: c.dark ? 0.28 : 0.18)),
                                                             GradientStop(offset: 1, color: c.pencil.with(alpha: 0))],
                                      start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1))
        var stroke = P.shape("Line", spark(values, w: 260, h: 40, closed: false), box: box, in: area, c.pencil)
        stroke.fill.on = false
        stroke.border = Border(on: true, color: c.pencil, width: 1.75, position: .center)
        let value = "$48,210"
        let vw = width(value, 34, Serif.regular, family: Serif.family)
        let delta = "+12.4%"
        let dw = ceil(width(delta, 12, "Semibold") + 30)
        return P.part([
            card(P.box(0, 0, 300, 176), c),
            words(String(localized: "Revenue"), x: 20, cy: 28, size: 13, weight: "Medium", color: c.ink2, name: "Label"),
            P.group("Period", [
                P.pill("Background", P.box(214, 17, 66, 22), c.tint),
                words(String(localized: "30 days"), x: 247, cy: 28, size: 12, weight: "Medium", color: c.ink2, align: .center, name: "Label"),
            ]),
            words(value, x: 20, cy: 68, size: 34, weight: Serif.regular, color: c.ink, family: Serif.family, tracking: -10, name: "Value"),
            P.group("Change", [
                P.pill("Background", P.box(20 + vw + 10, 60, dw, 22), c.wash(c.green)),
                icon("trending-up", 20 + vw + 22, 71, 13, c.green, weight: 2),
                words(delta, x: 20 + vw + 32, cy: 71, size: 12, weight: "Semibold", color: c.green, name: "Amount"),
            ]),
            words(String(localized: "Compared with last month"), x: 20, cy: 96, size: 12, color: c.ink3, name: "Detail"),
            P.group("Chart", [fill, stroke, P.circle("Latest", center: CGPoint(x: 280, y: 118), radius: 3.5, c.pencil).outlined(c.card, width: 2, position: .outside)]),
        ])
    }

    static let pricingCard = hugging("bezzle.pricing-card", "Pricing Card") { look in
        let c = Palette(dark: look.dark), w: CGFloat = 320
        let plan = "Studio"
        let popular = String(localized: "Most popular")
        let pw = ceil(width(popular, 12, "Medium") + 20)
        let price = "$24"
        let priceW = width(price, 48, Serif.regular, family: Serif.family)
        let blurb = P.paragraph(String(localized: "For small teams shipping polished work every week."), name: "Description", x: 24, y: 136,
                                width: w - 48, size: 14, color: c.ink2, line: 21)
        let buttonY = blurb.frame.maxY + 20
        let features = [String(localized: "Unlimited projects"), String(localized: "Shared libraries"),
                        String(localized: "Version history"), String(localized: "Priority support")]
        var list: [Node] = []
        let listTop = buttonY + 40 + 24 + 1 + 20
        for (i, feature) in features.enumerated() {
            let cy = listTop + CGFloat(i) * 32 + 10
            list.append(P.group(feature, [
                P.circle("Tick", center: CGPoint(x: 33, y: cy), radius: 9, c.wash(c.green)),
                icon("check", 33, cy, 12, c.green, weight: 2.6),
                words(feature, x: 52, cy: cy, size: 14, color: c.ink, name: "Label"),
            ]))
        }
        let bottom = listTop + CGFloat(features.count) * 32 + 12
        var bg = card(P.box(0, 0, w, bottom), c, lift: .raised)
        bg.border = P.border(c.pencil.with(alpha: c.dark ? 0.5 : 0.35), width: 1.5)
        return P.part([
            bg,
            words(plan, x: 24, cy: 36, size: 16, weight: "Semibold", color: c.ink, name: "Plan"),
            P.group("Badge", [
                P.pill("Background", P.box(w - 24 - pw, 24, pw, 24), c.wash(c.pencil)),
                words(popular, x: w - 24 - pw / 2, cy: 36, size: 12, weight: "Medium", color: c.pencil, align: .center, name: "Label"),
            ]),
            P.group("Price", [
                words(price, x: 24, cy: 92, size: 48, weight: Serif.regular, color: c.ink, family: Serif.family, tracking: -16, name: "Amount"),
                words(String(localized: "per seat"), x: 24 + priceW + 10, cy: 86, size: 13, weight: "Medium", color: c.ink2, name: "Unit"),
                words(String(localized: "a month"), x: 24 + priceW + 10, cy: 103, size: 13, color: c.ink3, name: "Period"),
            ]),
            blurb,
            button(String(localized: "Start free trial"), .primary, c, x: 24, y: buttonY, width: w - 48),
            P.rule(x: 24, y: buttonY + 64, width: w - 48, c.hairline, thickness: 1),
            P.group("Features", list),
        ])
    }

    /// Someone's initials on their colour.
    private static func avatar(_ initials: String, x: CGFloat, y: CGFloat, size s: CGFloat, tone: Int, _ c: Palette, ring: RGBA? = nil,
                               letters: CGFloat? = nil) -> Node {
        let (tint, ink) = c.tone(tone)
        var circle = P.oval("Circle", P.box(x, y, s, s), tint)
        if let ring { circle = circle.outlined(ring, width: 2, position: .outside) }
        return P.group("Avatar", [circle, words(initials, x: x + s / 2, cy: y + s / 2, size: letters ?? (s * 0.38).rounded(), weight: "Semibold", color: ink, align: .center, name: "Initials")])
    }

    static let avatars = hugging("bezzle.avatars", "Avatars") { look in
        let c = Palette(dark: look.dark)
        let people = [("AL", 48), ("TM", 40), ("MO", 32), ("JW", 24)]
        var made: [Node] = []
        var x: CGFloat = 0
        for (i, (initials, s)) in people.enumerated() {
            let size = CGFloat(s)
            var a = avatar(initials, x: x, y: 24 - size / 2, size: size, tone: [2, 0, 1, 4][i], c)
            if i == 1 {
                a = P.group("Avatar", [a, P.circle("Status", center: CGPoint(x: x + size - 5, y: 24 + size / 2 - 5), radius: 5, c.green).outlined(c.paper, width: 2, position: .outside)])
            }
            made.append(a)
            x += size + 14
        }
        return P.part(made)
    }

    static let avatarStack = hugging("bezzle.avatar-stack", "Avatar Stack") { look in
        let c = Palette(dark: look.dark)
        var made: [Node] = []
        for (i, initials) in ["AL", "TM", "MO", "JW"].enumerated() {
            made.append(avatar(initials, x: CGFloat(i) * 27, y: 0, size: 32, tone: [2, 0, 1, 3][i], c, ring: c.paper, letters: 11))
        }
        made.append(P.group("More", [
            P.oval("Circle", P.box(108, 0, 32, 32), c.card).outlined(c.paper, width: 2, position: .outside).casting(c.shadow(0.06, y: 1, blur: 2)),
            words("+5", x: 124, cy: 16, size: 12, weight: "Semibold", color: c.ink2, align: .center, name: "Count"),
        ]))
        made.append(words(String(localized: "Ada, Theo and 5 others"), x: 154, cy: 16, size: 13, color: c.ink2, name: "Label"))
        return P.part(made)
    }

    static let table = hugging("bezzle.table", "Table") { look in
        let c = Palette(dark: look.dark), w: CGFloat = 760
        let people: [(String, String, String, String, (String, RGBA?), String, Int)] = [
            ("AL", "Ada Lark", "ada@linden.studio", String(localized: "Owner"), (String(localized: "Active"), c.green), String(localized: "Now"), 2),
            ("TM", "Theo Marsh", "theo@linden.studio", String(localized: "Editor"), (String(localized: "Active"), c.green), String(localized: "2 hours ago"), 0),
            ("MO", "Mina Okafor", "mina@linden.studio", String(localized: "Editor"), (String(localized: "Invited"), c.amber), String(localized: "Yesterday"), 1),
            ("JW", "Jonas Weber", "jonas@linden.studio", String(localized: "Viewer"), (String(localized: "Away"), nil), String(localized: "Last week"), 3),
        ]
        let invite = button(String(localized: "Invite"), .primary, c, icon: "user-plus", height: 36)
        var made: [Node] = [
            card(P.box(0, 0, w, 72 + 40 + CGFloat(people.count) * 60), c),
            P.group("Toolbar", [
                words(String(localized: "Members"), x: 24, cy: 36, size: 20, weight: Serif.regular, color: c.ink, family: Serif.family, name: "Title"),
                words(String(localized: "4 people"), x: 24 + width(String(localized: "Members"), 20, Serif.regular, family: Serif.family) + 10, cy: 38,
                      size: 13, color: c.ink3, name: "Count"),
                well(P.box(w - 24 - invite.frame.width - 10 - 200, 18, 200, 36), c, radius: 9),
                icon("search", w - 24 - invite.frame.width - 10 - 200 + 20, 36, 15, c.ink3),
                words(String(localized: "Filter"), x: w - 24 - invite.frame.width - 10 - 200 + 36, cy: 36, size: 14, color: c.ink3, name: "Placeholder"),
                invite.moved(w - 24 - invite.frame.width, 18),
            ]),
        ]
        let columns: [(String, CGFloat)] = [(String(localized: "Name"), 60), (String(localized: "Role"), 340), (String(localized: "Status"), 468),
                                             (String(localized: "Last active"), 596)]
        var head: [Node] = [P.rect("Background", P.box(1, 72, w - 2, 40), c.ink.with(alpha: c.dark ? 0.03 : 0.025)),
                            P.rule(x: 0, y: 72, width: w, c.hairline, thickness: 1), box(on: false, x: 24, y: 83, c, mixed: true)]
        for (title, x) in columns { head.append(words(title, x: x, cy: 92, size: 12, weight: "Medium", color: c.ink3)) }
        made.append(P.group("Header", head))
        var rows: [Node] = []
        for (i, person) in people.enumerated() {
            let y = 112 + CGFloat(i) * 60, cy = y + 30
            let selected = i == 1
            var row: [Node] = [P.rule(x: 0, y: y, width: w, c.hairline, thickness: 1)]
            if selected { row.append(P.rect("Selection", P.box(1, y + 1, w - 2, 59), c.wash(c.pencil).with(alpha: c.dark ? 0.1 : 0.06))) }
            row += [
                box(on: selected, x: 24, y: cy - 9, c),
                avatar(person.0, x: 60, y: cy - 16, size: 32, tone: person.6, c),
                words(person.1, x: 104, cy: cy - 9, size: 14, weight: "Medium", color: c.ink, name: "Name"),
                words(person.2, x: 104, cy: cy + 9, size: 13, color: c.ink3, name: "Email"),
                words(person.3, x: 340, cy: cy, size: 14, color: c.ink2, name: "Role"),
                badge(person.4.0, color: person.4.1, dot: true, x: 468, y: cy - 12, c),
                words(person.5, x: 596, cy: cy, size: 14, color: c.ink2, name: "Last Active"),
                icon("ellipsis", w - 36, cy, 18, c.ink3),
            ]
            rows.append(P.group(person.1, row))
        }
        made.append(P.group("Rows", rows))
        return P.part(made)
    }

    static let modal = hugging("bezzle.modal", "Modal Dialog") { look in
        let c = Palette(dark: look.dark), w: CGFloat = 460
        let body = P.paragraph(String(localized: "People you invite can view and edit every page in Linden Website."), name: "Message",
                               x: 24, y: 62, width: w - 48, size: 14, color: c.ink2, line: 21)
        let fieldY = body.frame.maxY + 24
        let email = "theo@linden.studio", typed = "mina@"
        let cw = ceil(6 + 18 + 6 + width(email, 13, "Medium") + 6 + 12 + 6)
        let chip = P.group(email, [
            control(P.box(30, fieldY + 30, cw, 28), c, radius: 7),
            avatar("TM", x: 35, y: fieldY + 35, size: 18, tone: 0, c),
            words(email, x: 59, cy: fieldY + 44, size: 13, weight: "Medium", color: c.ink, name: "Label"),
            icon("x", 30 + cw - 13, fieldY + 44, 12, c.ink3),
        ])
        let typedX = 30 + cw + 8
        let x = typedX + width(typed, 14)
        let role = String(localized: "Can edit")
        let rw = ceil(width(role, 14, "Medium") + 14 + 8 + 16 + 10)
        let footY = fieldY + 24 + 44 + 28
        let send = button(String(localized: "Send invites"), .primary, c)
        let cancel = button(String(localized: "Cancel"), .secondary, c)
        let copy = String(localized: "Copy link")
        return P.part([
            card(P.box(0, 0, w, footY + 72), c, lift: .floating),
            words(String(localized: "Invite people"), x: 24, cy: 38, size: 22, weight: Serif.regular, color: c.ink, family: Serif.family, name: "Title"),
            P.group("Close", [P.frame(32, 32, x: w - 48, y: 20), icon("x", w - 32, 36, 18, c.ink3)]),
            body,
            words(String(localized: "Email addresses"), x: 24, cy: fieldY + 8, size: 13, weight: "Medium", color: c.ink, name: "Label"),
            P.group("Input", [
                focused(P.box(24, fieldY + 24, w - 48 - rw - 8, 40), c),
                chip,
                words(typed, x: typedX, cy: fieldY + 44, size: 14, color: c.ink, name: "Value"),
                P.rect("Caret", P.box(x + 1, fieldY + 34, 1.5, 20), c.pencil, radius: 0.75),
            ]),
            P.group("Role", [
                control(P.box(w - 24 - rw, fieldY + 24, rw, 40), c),
                words(role, x: w - 24 - rw + 14, cy: fieldY + 44, size: 14, weight: "Medium", color: c.ink, name: "Value"),
                icon("chevron-down", w - 24 - 18, fieldY + 44, 16, c.ink3),
            ]),
            P.rule(x: 0, y: footY, width: w, c.hairline, thickness: 1),
            P.group("Copy Link", [
                icon("link", 32, footY + 36, 16, c.pencil),
                words(copy, x: 46, cy: footY + 36, size: 14, weight: "Medium", color: c.pencil, name: "Label"),
            ]),
            send.moved(w - 24 - send.frame.width, footY + 16),
            cancel.moved(w - 24 - send.frame.width - 10 - cancel.frame.width, footY + 16),
        ])
    }

    static let dropdownMenu = hugging("bezzle.dropdown-menu", "Dropdown Menu") { look in
        let c = Palette(dark: look.dark), w: CGFloat = 240
        let items: [(String, String, [String], Bool)] = [
            ("pencil-line", String(localized: "Rename"), ["⌘", "R"], false),
            ("copy", String(localized: "Duplicate"), ["⌘", "D"], false),
            ("share-2", String(localized: "Share"), [], false),
            ("folder-input", String(localized: "Move to"), [], true),
        ]
        var made: [Node] = []
        var y: CGFloat = 6
        for (i, (name, title, shortcut, more)) in items.enumerated() {
            let cy = y + 17
            let on = i == 2
            var row: [Node] = []
            if on { row.append(P.rect("Highlight", P.box(6, y, w - 12, 34), c.wash(c.pencil), radius: 8)) }
            row.append(icon(name, 26, cy, 16, on ? c.pencil : c.ink2))
            row.append(words(title, x: 44, cy: cy, size: 14, color: c.ink, name: "Label"))
            if !shortcut.isEmpty { row.append(words(shortcut.joined(), x: w - 18, cy: cy, size: 13, color: c.ink3, align: .right, name: "Shortcut")) }
            if more { row.append(icon("chevron-right", w - 24, cy, 14, c.ink3)) }
            made.append(P.group(title, row))
            y += 34
        }
        made.append(P.rule(x: 6, y: y + 5, width: w - 12, c.hairline, thickness: 1))
        y += 11
        for (name, title, color) in [("archive", String(localized: "Archive"), c.ink), ("trash", String(localized: "Delete"), c.red)] {
            let cy = y + 17
            made.append(P.group(title, [
                icon(name, 26, cy, 16, color == c.ink ? c.ink2 : color),
                words(title, x: 44, cy: cy, size: 14, color: color, name: "Label"),
            ]))
            y += 34
        }
        return P.part([card(P.box(0, 0, w, y + 6), c, radius: 12, lift: .raised)] + made)
    }
}
