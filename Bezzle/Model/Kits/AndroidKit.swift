import Foundation
import CoreGraphics
import AppKit

private typealias P = Parts

/// Android 16 as Material 3 Expressive draws it: the baseline purple scheme and its tonal roles,
/// the M3 type scale in Roboto (or the Mac's own type while Roboto is not installed), and
/// Material Symbols Rounded.
nonisolated enum AndroidKit {
    static let kit = Kit(id: "android", title: "Android", paper: .hex("#FEF7FF"), darkPaper: .hex("#141218"), sections: [
        KitSection(title: "Bars", components: [statusBar, topAppBar, centerTopAppBar, mediumTopAppBar, largeTopAppBar,
                                               searchBar, tabs, navigationBar, bottomAppBar, gestureBar]),
        KitSection(title: "Buttons", components: [filledButton, tonalButton, outlinedButton, elevatedButton, textButton,
                                                  iconButton, filledIconButton, tonalIconButton, outlinedIconButton,
                                                  smallFab, fab, largeFab, extendedFab, segmentedButton]),
        KitSection(title: "Selection", components: [switchOn, switchOff, checkboxChecked, checkboxUnchecked, radioSelected,
                                                    radioUnselected, slider, assistChip, filterChip, inputChip, suggestionChip]),
        KitSection(title: "Text Fields", components: [filledTextField, outlinedTextField]),
        KitSection(title: "Containment", components: [elevatedCard, filledCard, outlinedCard, listItem, twoLineListItem,
                                                      threeLineListItem, dialog, bottomSheet, navigationDrawer, menu, divider]),
        KitSection(title: "Feedback", components: [snackbar, badge, linearProgress, circularProgress]),
    ])

    // MARK: Colours and type

    /// The baseline scheme's colour roles, light or dark.
    struct Palette {
        let dark: Bool
        private func pick(_ light: String, _ night: String) -> RGBA { .hex(dark ? night : light) }
        var primary: RGBA { pick("#6750A4", "#D0BCFF") }
        var onPrimary: RGBA { pick("#FFFFFF", "#381E72") }
        var primaryContainer: RGBA { pick("#EADDFF", "#4F378B") }
        var onPrimaryContainer: RGBA { pick("#4F378B", "#EADDFF") }
        var secondary: RGBA { pick("#625B71", "#CCC2DC") }
        var secondaryContainer: RGBA { pick("#E8DEF8", "#4A4458") }
        var onSecondaryContainer: RGBA { pick("#4A4458", "#E8DEF8") }
        var tertiaryContainer: RGBA { pick("#FFD8E4", "#633B48") }
        var error: RGBA { pick("#B3261E", "#F2B8B5") }
        var onError: RGBA { pick("#FFFFFF", "#601410") }
        var surface: RGBA { pick("#FEF7FF", "#141218") }
        var onSurface: RGBA { pick("#1D1B20", "#E6E0E9") }
        var onSurfaceVariant: RGBA { pick("#49454F", "#CAC4D0") }
        var surfaceContainerLow: RGBA { pick("#F7F2FA", "#1D1B20") }
        var surfaceContainer: RGBA { pick("#F3EDF7", "#211F26") }
        var surfaceContainerHigh: RGBA { pick("#ECE6F0", "#2B2930") }
        var surfaceContainerHighest: RGBA { pick("#E6E0E9", "#36343B") }
        var outline: RGBA { pick("#79747E", "#938F99") }
        var outlineVariant: RGBA { pick("#CAC4D0", "#49454F") }
        var inverseSurface: RGBA { pick("#322F35", "#E6E0E9") }
        var inverseOnSurface: RGBA { pick("#F5EFF7", "#322F35") }
        var inversePrimary: RGBA { pick("#D0BCFF", "#6750A4") }
    }

    /// A style of the M3 type scale: size, weight, line height and letter spacing, in points.
    struct Face {
        let size: CGFloat
        let weight: String
        let line: CGFloat
        let spacing: CGFloat

        /// Roboto where it is installed; else the Mac's own type, which keeps its own spacing.
        static let family: String = NSFontManager.shared.availableMembers(ofFontFamily: "Roboto") != nil ? "Roboto" : TextStyle.system
        /// In thousandths of the size, as a text style counts it.
        var tracking: CGFloat { Face.family == TextStyle.system ? 0 : spacing / size * 1000 }

        static let displaySmall = Face(size: 36, weight: "Regular", line: 44, spacing: 0)
        static let headlineMedium = Face(size: 28, weight: "Regular", line: 36, spacing: 0)
        static let headlineSmall = Face(size: 24, weight: "Regular", line: 32, spacing: 0)
        static let titleLarge = Face(size: 22, weight: "Regular", line: 28, spacing: 0)
        static let titleMedium = Face(size: 16, weight: "Medium", line: 24, spacing: 0.15)
        static let titleSmall = Face(size: 14, weight: "Medium", line: 20, spacing: 0.1)
        static let bodyLarge = Face(size: 16, weight: "Regular", line: 24, spacing: 0.5)
        static let bodyMedium = Face(size: 14, weight: "Regular", line: 20, spacing: 0.25)
        static let bodySmall = Face(size: 12, weight: "Regular", line: 16, spacing: 0.4)
        static let labelLarge = Face(size: 14, weight: "Medium", line: 20, spacing: 0.1)
        static let labelMedium = Face(size: 12, weight: "Medium", line: 16, spacing: 0.5)
        static let labelSmall = Face(size: 11, weight: "Medium", line: 16, spacing: 0.5)
    }

    // MARK: Drawing helpers

    /// One line of words in its line box, whose top is `top`: starting at `x`, centred on it or ending at it.
    private static func say(_ s: String, _ f: Face, x: CGFloat, top: CGFloat, _ color: RGBA, align: TextAlign = .left,
                            name: String? = nil) -> Node {
        P.text(s, name: name, x: x, y: top, size: f.size, weight: f.weight, color: color, family: Face.family, align: align,
               tracking: f.tracking, line: f.line)
    }

    /// Words wrapped to a width, its lines the style's height apart.
    private static func prose(_ s: String, _ f: Face, x: CGFloat, top: CGFloat, width: CGFloat, _ color: RGBA,
                              name: String? = nil) -> Node {
        P.paragraph(s, name: name, x: x, y: top, width: width, size: f.size, weight: f.weight, color: color, family: Face.family,
                    line: f.line, tracking: f.tracking)
    }

    private static func measure(_ s: String, _ f: Face) -> CGFloat {
        P.width(of: s, size: f.size, weight: f.weight, family: Face.family, tracking: f.tracking).rounded(.up)
    }

    /// A Material Symbol, outlined or filled.
    private static func symbol(_ name: String, center c: CGPoint, size: CGFloat = 24, _ color: RGBA, filled: Bool = false) -> Node {
        P.icon(name, .material, center: c, size: size, color, style: filled ? 1 : 0)
    }

    /// A rounded box that draws only its edge.
    private static func ring(_ name: String, _ r: CGRect, radius: CGFloat, _ color: RGBA, width: CGFloat = 1) -> Node {
        var n = P.rect(name, r, color, radius: radius).outlined(color, width: width)
        n.fill.on = false
        return n
    }

    /// The M3 elevation levels as the shadows they cast.
    fileprivate static func elevation(_ level: Int) -> [Shadow] {
        let key = RGBA.hex("#0000004D"), ambient = RGBA.hex("#00000026")
        switch level {
        case 1: return [P.shadow(y: 1, blur: 2, key), P.shadow(y: 1, blur: 3, ambient, spread: 1)]
        case 2: return [P.shadow(y: 1, blur: 2, key), P.shadow(y: 2, blur: 6, ambient, spread: 2)]
        default: return [P.shadow(y: 1, blur: 3, key), P.shadow(y: 4, blur: 8, ambient, spread: 3)]
        }
    }

    /// A round avatar with an initial on the primary container.
    private static func avatar(_ c: Palette, center p: CGPoint, diameter d: CGFloat, initial: String) -> Node {
        let f: Face = d >= 40 ? .titleMedium : .labelLarge
        return P.group("Avatar", [
            P.circle("Background", center: p, radius: d / 2, c.primaryContainer),
            say(initial, f, x: p.x, top: p.y - f.line / 2, c.onPrimaryContainer, align: .center, name: "Initial"),
        ])
    }

    /// Where a picture goes: a soft wash of the scheme's containers, a picture sign in the middle.
    private static func media(_ c: Palette, _ r: CGRect, corners: [CGFloat], sign: CGFloat = 40) -> Node {
        var image = P.rect("Image", r, c.primaryContainer, corners: corners)
        image.fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: c.primaryContainer),
                                                               GradientStop(offset: 1, color: c.tertiaryContainer)],
                                       start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1))
        return P.group("Media", [
            image,
            symbol("image", center: CGPoint(x: r.midX, y: r.midY), size: sign, c.onPrimaryContainer.with(alpha: 0.55)),
        ])
    }

    /// A band along a circle, round at its ends, from one angle to another in degrees clockwise
    /// from three o'clock, as an outline to fill.
    private static func arc(center c: CGPoint, radius r: CGFloat, width t: CGFloat, from a0: CGFloat, to a1: CGFloat) -> String {
        func pt(_ rad: CGFloat, _ a: CGFloat) -> String {
            let x = c.x + rad * cos(a * .pi / 180), y = c.y + rad * sin(a * .pi / 180)
            return String(format: "%.3f %.3f", x, y)
        }
        let outer = r + t / 2, inner = r - t / 2, cap = t / 2
        let large = a1 - a0 > 180 ? 1 : 0
        return "M\(pt(outer, a0))A\(outer) \(outer) 0 \(large) 1 \(pt(outer, a1))A\(cap) \(cap) 0 0 1 \(pt(inner, a1))"
            + "A\(inner) \(inner) 0 \(large) 0 \(pt(inner, a0))A\(cap) \(cap) 0 0 1 \(pt(outer, a0))Z"
    }

    /// A part as big as it measures, made light.
    private static func fixed(_ id: String, _ title: LocalizedStringResource, make: @escaping @Sendable (KitLook) -> Node) -> Component {
        Component(id: id, title: title, size: make(KitLook(width: 0)).frame.size, make: make)
    }

    /// A part that spans a width, as tall as it measures at `width`.
    private static func spanning(_ id: String, _ title: LocalizedStringResource, width: CGFloat, fit: Component.Fit, minWidth: CGFloat,
                                 make: @escaping @Sendable (KitLook) -> Node) -> Component {
        Component(id: id, title: title, size: CGSize(width: width, height: make(KitLook(width: width)).frame.height), fit: fit,
                  minWidth: minWidth, make: make)
    }

    // MARK: - Bars

    static let statusBar = Component(id: "android.status-bar", title: "Status Bar", size: CGSize(width: 412, height: 52), fit: .top, minWidth: 320) { look in
        let c = Palette(dark: look.dark), w = look.width, mid: CGFloat = 26
        return P.part([
            P.frame(w, 52),
            say("9:30", Face(size: 14, weight: "Medium", line: 20, spacing: 0.14), x: 24, top: mid - 10, c.onSurface, name: "Time"),
            P.group("Signs", [
                symbol("signal_wifi_4_bar", center: CGPoint(x: w - 81, y: mid), size: 20, c.onSurface, filled: true),
                symbol("signal_cellular_4_bar", center: CGPoint(x: w - 60, y: mid), size: 20, c.onSurface, filled: true),
                symbol("battery_android_full", center: CGPoint(x: w - 36, y: mid), size: 24, c.onSurface, filled: true),
            ]),
        ])
    }

    /// The navigation icon at the start of a top app bar's row and the actions at its end, icons
    /// in 48-point buttons four points in from the edges.
    private static func appBarRow(_ c: Palette, w: CGFloat, leading: String, actions: [String]) -> [Node] {
        var row = [symbol(leading, center: CGPoint(x: 28, y: 32), c.onSurface)]
        if !actions.isEmpty {
            let icons = actions.reversed().enumerated().map { i, name in
                symbol(name, center: CGPoint(x: w - 28 - 48 * CGFloat(i), y: 32), c.onSurfaceVariant)
            }
            row.append(P.group("Actions", icons.reversed()))
        }
        return row
    }

    static let topAppBar = Component(id: "android.top-app-bar", title: "Top App Bar", size: CGSize(width: 412, height: 64), fit: .top, minWidth: 320) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([P.rect("Background", P.box(0, 0, w, 64), c.surface)]
            + appBarRow(c, w: w, leading: "arrow_back", actions: ["search", "more_vert"])
            + [say(String(localized: "Inbox"), .titleLarge, x: 56, top: 18, c.onSurface, name: "Title")])
    }

    static let centerTopAppBar = Component(id: "android.center-aligned-top-app-bar", title: "Center-Aligned Top App Bar", size: CGSize(width: 412, height: 64), fit: .top, minWidth: 320) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([P.rect("Background", P.box(0, 0, w, 64), c.surface)]
            + appBarRow(c, w: w, leading: "menu", actions: [])
            + [say(String(localized: "Photos"), .titleLarge, x: w / 2, top: 18, c.onSurface, align: .center, name: "Title"),
               avatar(c, center: CGPoint(x: w - 28, y: 32), diameter: 32, initial: "A")])
    }

    static let mediumTopAppBar = Component(id: "android.medium-top-app-bar", title: "Medium Top App Bar", size: CGSize(width: 412, height: 112), fit: .top, minWidth: 320) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([P.rect("Background", P.box(0, 0, w, 112), c.surface)]
            + appBarRow(c, w: w, leading: "arrow_back", actions: ["search", "more_vert"])
            + [say(String(localized: "Settings"), .headlineMedium, x: 16, top: 112 - 16 - 36, c.onSurface, name: "Title")])
    }

    static let largeTopAppBar = Component(id: "android.large-top-app-bar", title: "Large Top App Bar", size: CGSize(width: 412, height: 120), fit: .top, minWidth: 320) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([P.rect("Background", P.box(0, 0, w, 120), c.surface)]
            + appBarRow(c, w: w, leading: "arrow_back", actions: ["edit", "more_vert"])
            + [say(String(localized: "Messages"), .displaySmall, x: 16, top: 120 - 16 - 44, c.onSurface, name: "Title")])
    }

    static let searchBar = Component(id: "android.search-bar", title: "Search Bar", size: CGSize(width: 380, height: 56), fit: .across(margin: 16), minWidth: 240) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([
            P.pill("Background", P.box(0, 0, w, 56), c.surfaceContainerHigh),
            symbol("menu", center: CGPoint(x: 28, y: 28), c.onSurface),
            say(String(localized: "Search"), .bodyLarge, x: 56, top: 16, c.onSurfaceVariant, name: "Placeholder"),
            avatar(c, center: CGPoint(x: w - 16 - 15, y: 28), diameter: 30, initial: "A"),
        ])
    }

    static let tabs = Component(id: "android.tabs", title: "Tabs", size: CGSize(width: 412, height: 48), fit: .across(margin: 0), minWidth: 280) { look in
        let c = Palette(dark: look.dark), w = look.width
        let labels = [String(localized: "Video"), String(localized: "Photos"), String(localized: "Audio")]
        let step = w / CGFloat(labels.count)
        var items: [Node] = []
        for (i, label) in labels.enumerated() {
            let x = step * (CGFloat(i) + 0.5), on = i == 0
            var tab = [say(label, .titleSmall, x: x, top: 14, on ? c.primary : c.onSurfaceVariant, align: .center, name: "Label")]
            if on {
                let iw = max(24, measure(label, .titleSmall))
                tab.append(P.rect("Indicator", P.box((x - iw / 2).rounded(), 45, iw, 3), c.primary, corners: [3, 3, 0, 0]))
            }
            items.append(P.group(label, tab))
        }
        return P.part([
            P.rect("Background", P.box(0, 0, w, 48), c.surface),
            P.rule("Divider", x: 0, y: 47, width: w, c.outlineVariant, thickness: 1),
            P.group("Tabs", items),
        ])
    }

    static let navigationBar = Component(id: "android.navigation-bar", title: "Navigation Bar", size: CGSize(width: 412, height: 64), fit: .bottom, minWidth: 320) { look in
        let c = Palette(dark: look.dark), w = look.width
        let items: [(String, String)] = [("home", String(localized: "Home")), ("search", String(localized: "Search")),
                                         ("bookmark", String(localized: "Saved")), ("person", String(localized: "Profile"))]
        let step = w / CGFloat(items.count)
        var tabs: [Node] = []
        for (i, (icon, label)) in items.enumerated() {
            let x = (step * (CGFloat(i) + 0.5)).rounded(), on = i == 0
            var tab: [Node] = []
            if on { tab.append(P.pill("Indicator", P.box(x - 28, 6, 56, 32), c.secondaryContainer)) }
            tab.append(symbol(icon, center: CGPoint(x: x, y: 22), on ? c.onSecondaryContainer : c.onSurfaceVariant, filled: on))
            tab.append(say(label, .labelMedium, x: x, top: 42, on ? c.secondary : c.onSurfaceVariant, align: .center, name: "Label"))
            tabs.append(P.group(label, tab))
        }
        return P.part([
            P.rect("Background", P.box(0, 0, w, 64), c.surfaceContainer),
            P.group("Destinations", tabs),
        ])
    }

    static let bottomAppBar = Component(id: "android.bottom-app-bar", title: "Bottom App Bar", size: CGSize(width: 412, height: 80), fit: .bottom, minWidth: 320) { look in
        let c = Palette(dark: look.dark), w = look.width
        let icons = ["check_box", "edit", "mic", "image"].enumerated().map { i, name in
            symbol(name, center: CGPoint(x: 28 + 48 * CGFloat(i), y: 40), c.onSurfaceVariant)
        }
        return P.part([
            P.rect("Background", P.box(0, 0, w, 80), c.surfaceContainer),
            P.group("Actions", icons),
            P.group("FAB", [
                P.rect("Background", P.box(w - 16 - 56, 12, 56, 56), c.primaryContainer, radius: 16),
                symbol("add", center: CGPoint(x: w - 16 - 28, y: 40), c.onPrimaryContainer),
            ]),
        ])
    }

    static let gestureBar = Component(id: "android.gesture-navigation", title: "Gesture Navigation", size: CGSize(width: 412, height: 24), fit: .bottom, minWidth: 320) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([
            P.frame(w, 24),
            P.pill("Handle", P.box(((w - 108) / 2).rounded(), 10, 108, 4), c.onSurface),
        ])
    }

    // MARK: - Buttons

    enum Emphasis { case filled, tonal, outlined, elevated, text }

    /// A common button 40 high, as wide as its label asks, its top left at 0, 0.
    private static func button(_ label: String, _ e: Emphasis, _ c: Palette) -> Node {
        let pad: CGFloat = e == .text ? 12 : 16
        let w = measure(label, .labelLarge) + pad * 2
        let r = P.box(0, 0, w, 40)
        let background: Node, ink: RGBA
        switch e {
        case .filled: background = P.pill("Background", r, c.primary); ink = c.onPrimary
        case .tonal: background = P.pill("Background", r, c.secondaryContainer); ink = c.onSecondaryContainer
        case .outlined: background = ring("Outline", r, radius: 20, c.outlineVariant); ink = c.onSurfaceVariant
        case .elevated: background = P.pill("Background", r, c.surfaceContainerLow).raised(1); ink = c.primary
        case .text: background = P.frame(w, 40); ink = c.primary
        }
        return P.group(label, [background, say(label, .labelLarge, x: w / 2, top: 10, ink, align: .center, name: "Label")])
    }

    static let filledButton = fixed("android.filled-button", "Filled Button") { look in
        P.part(button(String(localized: "Continue"), .filled, Palette(dark: look.dark)).children)
    }

    static let tonalButton = fixed("android.tonal-button", "Tonal Button") { look in
        P.part(button(String(localized: "Add to list"), .tonal, Palette(dark: look.dark)).children)
    }

    static let outlinedButton = fixed("android.outlined-button", "Outlined Button") { look in
        P.part(button(String(localized: "Learn more"), .outlined, Palette(dark: look.dark)).children)
    }

    static let elevatedButton = fixed("android.elevated-button", "Elevated Button") { look in
        P.part(button(String(localized: "Follow"), .elevated, Palette(dark: look.dark)).children)
    }

    static let textButton = fixed("android.text-button", "Text Button") { look in
        P.part(button(String(localized: "Cancel"), .text, Palette(dark: look.dark)).children)
    }

    private static func iconButtonNode(_ e: Emphasis, _ c: Palette) -> Node {
        let r = P.box(0, 0, 40, 40), mid = CGPoint(x: 20, y: 20)
        switch e {
        case .filled:
            return P.part([P.pill("Background", r, c.primary), symbol("settings", center: mid, c.onPrimary)])
        case .tonal:
            return P.part([P.pill("Background", r, c.secondaryContainer), symbol("settings", center: mid, c.onSecondaryContainer)])
        case .outlined:
            return P.part([ring("Outline", r, radius: 20, c.outlineVariant), symbol("settings", center: mid, c.onSurfaceVariant)])
        default:
            return P.part([P.frame(40, 40), symbol("settings", center: mid, c.onSurfaceVariant)])
        }
    }

    static let iconButton = Component(id: "android.icon-button", title: "Icon Button", size: CGSize(width: 40, height: 40)) { look in
        iconButtonNode(.text, Palette(dark: look.dark))
    }

    static let filledIconButton = Component(id: "android.filled-icon-button", title: "Filled Icon Button", size: CGSize(width: 40, height: 40)) { look in
        iconButtonNode(.filled, Palette(dark: look.dark))
    }

    static let tonalIconButton = Component(id: "android.tonal-icon-button", title: "Tonal Icon Button", size: CGSize(width: 40, height: 40)) { look in
        iconButtonNode(.tonal, Palette(dark: look.dark))
    }

    static let outlinedIconButton = Component(id: "android.outlined-icon-button", title: "Outlined Icon Button", size: CGSize(width: 40, height: 40)) { look in
        iconButtonNode(.outlined, Palette(dark: look.dark))
    }

    /// A floating action button on the primary container, lifted.
    private static func fabNode(_ c: Palette, side: CGFloat, radius: CGFloat, icon: CGFloat) -> Node {
        P.part([
            P.rect("Background", P.box(0, 0, side, side), c.primaryContainer, radius: radius).raised(3),
            symbol("edit", center: CGPoint(x: side / 2, y: side / 2), size: icon, c.onPrimaryContainer),
        ])
    }

    static let smallFab = Component(id: "android.small-fab", title: "Small FAB", size: CGSize(width: 40, height: 40)) { look in
        fabNode(Palette(dark: look.dark), side: 40, radius: 12, icon: 24)
    }

    static let fab = Component(id: "android.fab", title: "FAB", size: CGSize(width: 56, height: 56)) { look in
        fabNode(Palette(dark: look.dark), side: 56, radius: 16, icon: 24)
    }

    static let largeFab = Component(id: "android.large-fab", title: "Large FAB", size: CGSize(width: 96, height: 96)) { look in
        fabNode(Palette(dark: look.dark), side: 96, radius: 28, icon: 36)
    }

    static let extendedFab = fixed("android.extended-fab", "Extended FAB") { look in
        let c = Palette(dark: look.dark), label = String(localized: "Compose")
        let w = 16 + 24 + 8 + measure(label, .titleMedium) + 16
        return P.part([
            P.rect("Background", P.box(0, 0, w, 56), c.primaryContainer, radius: 16).raised(3),
            symbol("edit", center: CGPoint(x: 28, y: 28), c.onPrimaryContainer),
            say(label, .titleMedium, x: 48, top: 16, c.onPrimaryContainer, name: "Label"),
        ])
    }

    static let segmentedButton = Component(id: "android.segmented-button", title: "Segmented Button", size: CGSize(width: 380, height: 40), fit: .across(margin: 16), minWidth: 240) { look in
        let c = Palette(dark: look.dark), w = look.width
        let labels = [String(localized: "Day"), String(localized: "Week"), String(localized: "Month")]
        let chosen = 1, n = CGFloat(labels.count)
        var segments: [Node] = [], dividers: [Node] = []
        for (i, label) in labels.enumerated() {
            let x0 = (w * CGFloat(i) / n).rounded(), x1 = (w * CGFloat(i + 1) / n).rounded(), mid = (x0 + x1) / 2
            var segment: [Node] = []
            if i == chosen {
                let corners: [CGFloat] = i == 0 ? [20, 0, 0, 20] : i == labels.count - 1 ? [0, 20, 20, 0] : [0, 0, 0, 0]
                segment.append(P.rect("Background", P.box(x0, 0, x1 - x0, 40), c.secondaryContainer, corners: corners))
                let tw = measure(label, .labelLarge), start = (mid - (18 + 8 + tw) / 2).rounded()
                segment.append(symbol("check", center: CGPoint(x: start + 9, y: 20), size: 18, c.onSecondaryContainer))
                segment.append(say(label, .labelLarge, x: start + 26, top: 10, c.onSecondaryContainer, name: "Label"))
            } else {
                segment.append(say(label, .labelLarge, x: mid, top: 10, c.onSurface, align: .center, name: "Label"))
            }
            segments.append(P.group(label, segment))
            if i > 0 { dividers.append(P.rect("Divider", P.box(x0 - 0.5, 0, 1, 40), c.outline)) }
        }
        return P.part([P.frame(w, 40)] + segments + [P.group("Dividers", dividers), ring("Outline", P.box(0, 0, w, 40), radius: 20, c.outline)])
    }

    // MARK: - Selection

    /// A switch 52 by 32, its top left at 0, 0.
    private static func switchNodes(_ c: Palette, on: Bool) -> [Node] {
        if on {
            return [
                P.pill("Track", P.box(0, 0, 52, 32), c.primary),
                P.circle("Handle", center: CGPoint(x: 36, y: 16), radius: 12, c.onPrimary),
                symbol("check", center: CGPoint(x: 36, y: 16), size: 16, c.onPrimaryContainer),
            ]
        }
        return [
            P.pill("Track", P.box(0, 0, 52, 32), c.surfaceContainerHighest).outlined(c.outline, width: 2),
            P.circle("Handle", center: CGPoint(x: 16, y: 16), radius: 8, c.outline),
        ]
    }

    static let switchOn = Component(id: "android.switch-on", title: "Switch On", size: CGSize(width: 52, height: 32)) { look in
        P.part(switchNodes(Palette(dark: look.dark), on: true))
    }

    static let switchOff = Component(id: "android.switch-off", title: "Switch Off", size: CGSize(width: 52, height: 32)) { look in
        P.part(switchNodes(Palette(dark: look.dark), on: false))
    }

    /// A checkbox 18 square, its top left at 0, 0.
    private static func checkboxNodes(_ c: Palette, checked: Bool) -> [Node] {
        guard checked else { return [ring("Box", P.box(0, 0, 18, 18), radius: 2, c.onSurfaceVariant, width: 2)] }
        return [
            P.rect("Box", P.box(0, 0, 18, 18), c.primary, radius: 2),
            P.group("Check", [
                P.line("Short", from: CGPoint(x: 4.2, y: 9.3), to: CGPoint(x: 7.4, y: 12.5), c.onPrimary, width: 2),
                P.line("Long", from: CGPoint(x: 7.4, y: 12.5), to: CGPoint(x: 13.8, y: 6.1), c.onPrimary, width: 2),
            ]),
        ]
    }

    static let checkboxChecked = Component(id: "android.checkbox-checked", title: "Checkbox Checked", size: CGSize(width: 18, height: 18)) { look in
        P.part(checkboxNodes(Palette(dark: look.dark), checked: true))
    }

    static let checkboxUnchecked = Component(id: "android.checkbox-unchecked", title: "Checkbox Unchecked", size: CGSize(width: 18, height: 18)) { look in
        P.part(checkboxNodes(Palette(dark: look.dark), checked: false))
    }

    static let radioSelected = Component(id: "android.radio-selected", title: "Radio Button Selected", size: CGSize(width: 20, height: 20)) { look in
        let c = Palette(dark: look.dark)
        return P.part([
            ring("Ring", P.box(0, 0, 20, 20), radius: 10, c.primary, width: 2),
            P.circle("Dot", center: CGPoint(x: 10, y: 10), radius: 5, c.primary),
        ])
    }

    static let radioUnselected = Component(id: "android.radio-unselected", title: "Radio Button Unselected", size: CGSize(width: 20, height: 20)) { look in
        P.part([ring("Ring", P.box(0, 0, 20, 20), radius: 10, Palette(dark: look.dark).onSurfaceVariant, width: 2)])
    }

    static let slider = Component(id: "android.slider", title: "Slider", size: CGSize(width: 380, height: 44), fit: .across(margin: 16), minWidth: 160) { look in
        let c = Palette(dark: look.dark), w = look.width
        let handle = (w * 0.4).rounded()
        return P.part([
            P.frame(w, 44),
            P.rect("Active Track", P.box(0, 14, handle - 8, 16), c.primary, corners: [8, 2, 2, 8]),
            P.rect("Inactive Track", P.box(handle + 8, 14, w - handle - 8, 16), c.secondaryContainer, corners: [2, 8, 8, 2]),
            P.circle("Stop Indicator", center: CGPoint(x: w - 8, y: 22), radius: 2, c.primary),
            P.rect("Handle", P.box(handle - 2, 0, 4, 44), c.primary, radius: 2),
        ])
    }

    /// A chip 32 high: an icon or none before the label, an icon or none after it.
    private static func chip(_ c: Palette, label: String, leading: String? = nil, trailing: String? = nil, selected: Bool = false,
                             ink: RGBA, iconInk: RGBA) -> Node {
        let tw = measure(label, .labelLarge)
        let start: CGFloat = leading != nil ? 8 + 18 + 8 : trailing != nil ? 12 : 16
        let w = start + tw + (trailing != nil ? 8 + 18 + 8 : 16)
        let r = P.box(0, 0, w, 32)
        var nodes = [selected ? P.rect("Background", r, c.secondaryContainer, radius: 8) : ring("Outline", r, radius: 8, c.outlineVariant)]
        if let leading { nodes.append(symbol(leading, center: CGPoint(x: 17, y: 16), size: 18, iconInk)) }
        nodes.append(say(label, .labelLarge, x: start, top: 6, ink, name: "Label"))
        if let trailing { nodes.append(symbol(trailing, center: CGPoint(x: w - 17, y: 16), size: 18, iconInk)) }
        return P.part(nodes)
    }

    static let assistChip = fixed("android.assist-chip", "Assist Chip") { look in
        let c = Palette(dark: look.dark)
        return chip(c, label: String(localized: "Add to calendar"), leading: "event", ink: c.onSurface, iconInk: c.primary)
    }

    static let filterChip = fixed("android.filter-chip", "Filter Chip") { look in
        let c = Palette(dark: look.dark)
        return chip(c, label: String(localized: "Nearby"), leading: "check", selected: true, ink: c.onSecondaryContainer, iconInk: c.onSecondaryContainer)
    }

    static let inputChip = fixed("android.input-chip", "Input Chip") { look in
        let c = Palette(dark: look.dark)
        return chip(c, label: String(localized: "Travel"), trailing: "close", ink: c.onSurfaceVariant, iconInk: c.onSurfaceVariant)
    }

    static let suggestionChip = fixed("android.suggestion-chip", "Suggestion Chip") { look in
        let c = Palette(dark: look.dark)
        return chip(c, label: String(localized: "Sounds good"), ink: c.onSurfaceVariant, iconInk: c.onSurfaceVariant)
    }

    // MARK: - Text fields

    static let filledTextField = Component(id: "android.filled-text-field", title: "Filled Text Field", size: CGSize(width: 380, height: 56), fit: .across(margin: 16), minWidth: 240) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([
            P.rect("Background", P.box(0, 0, w, 56), c.surfaceContainerHighest, corners: [4, 4, 0, 0]),
            P.rule("Active Indicator", x: 0, y: 55, width: w, c.onSurfaceVariant, thickness: 1),
            say(String(localized: "Email"), .bodySmall, x: 16, top: 8, c.onSurfaceVariant, name: "Label"),
            say("alex@example.com", .bodyLarge, x: 16, top: 24, c.onSurface, name: "Input"),
            symbol("cancel", center: CGPoint(x: w - 24, y: 28), c.onSurfaceVariant),
        ])
    }

    static let outlinedTextField = Component(id: "android.outlined-text-field", title: "Outlined Text Field", size: CGSize(width: 380, height: 64), fit: .across(margin: 16), minWidth: 240) { look in
        let c = Palette(dark: look.dark), w = look.width
        let label = String(localized: "Name")
        // The outline, half a point in so it lies inside, open where the label sits on it.
        let gapStart: CGFloat = 12, gapEnd = 16 + measure(label, .bodySmall) + 4
        let l: CGFloat = 0.5, t: CGFloat = 8.5, r = w - 0.5, b: CGFloat = 63.5, k: CGFloat = 3.5
        func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
        let data = "M\(f(gapEnd)) \(f(t))H\(f(r - k))A\(k) \(k) 0 0 1 \(f(r)) \(f(t + k))V\(f(b - k))A\(k) \(k) 0 0 1 \(f(r - k)) \(f(b))"
            + "H\(f(l + k))A\(k) \(k) 0 0 1 \(f(l)) \(f(b - k))V\(f(t + k))A\(k) \(k) 0 0 1 \(f(l + k)) \(f(t))H\(f(gapStart))"
        let box = CGRect(x: l, y: t, width: r - l, height: b - t)
        var outline = P.shape("Outline", data, box: box, in: box, c.outline).outlined(c.outline, width: 1, position: .center)
        outline.fill.on = false
        return P.part([
            P.frame(w, 64),
            outline,
            say(label, .bodySmall, x: 16, top: 0, c.onSurfaceVariant, name: "Label"),
            say("Alex Morgan", .bodyLarge, x: 16, top: 24, c.onSurface, name: "Input"),
        ])
    }

    // MARK: - Containment

    enum CardStyle { case elevated, filled, outlined }

    private static func card(_ look: KitLook, _ style: CardStyle) -> Node {
        let c = Palette(dark: look.dark), w = look.width
        let inset: CGFloat = style == .outlined ? 1 : 0
        let text = prose(String(localized: "A quiet wooden cabin by the water, with a sauna and a rowing boat."), .bodyMedium,
                         x: 16, top: 188 + 16 + 28 + 20 + 8, width: w - 32, c.onSurfaceVariant, name: "Supporting Text")
        let top = text.frame.maxY + 24
        let primary = button(String(localized: "Book"), .filled, c)
        let secondary = button(String(localized: "Details"), .outlined, c)
        let actions = P.group("Actions", [
            secondary.moved(w - 16 - primary.frame.width - 8 - secondary.frame.width, top),
            primary.moved(w - 16 - primary.frame.width, top),
        ])
        let h = top + 40 + 16
        let r = P.box(0, 0, w, h)
        let background: Node = switch style {
        case .elevated: P.rect("Background", r, c.surfaceContainerLow, radius: 12).raised(1)
        case .filled: P.rect("Background", r, c.surfaceContainerHighest, radius: 12)
        case .outlined: P.rect("Background", r, c.surface, radius: 12).outlined(c.outlineVariant)
        }
        return P.part([
            background,
            media(c, P.box(inset, inset, w - inset * 2, 188 - inset), corners: [12 - inset, 12 - inset, 0, 0]),
            say(String(localized: "Lakeside Cabin"), .titleLarge, x: 16, top: 188 + 16, c.onSurface, name: "Title"),
            say("Lake Tahoe, California", .bodyMedium, x: 16, top: 188 + 16 + 28, c.onSurfaceVariant, name: "Subhead"),
            text,
            actions,
        ])
    }

    static let elevatedCard = spanning("android.elevated-card", "Elevated Card", width: 380, fit: .across(margin: 16), minWidth: 280) { look in
        card(look, .elevated)
    }

    static let filledCard = spanning("android.filled-card", "Filled Card", width: 380, fit: .across(margin: 16), minWidth: 280) { look in
        card(look, .filled)
    }

    static let outlinedCard = spanning("android.outlined-card", "Outlined Card", width: 380, fit: .across(margin: 16), minWidth: 280) { look in
        card(look, .outlined)
    }

    static let listItem = Component(id: "android.list-item", title: "List Item", size: CGSize(width: 412, height: 56), fit: .across(margin: 0), minWidth: 320) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([
            P.rect("Background", P.box(0, 0, w, 56), c.surface),
            symbol("notifications", center: CGPoint(x: 28, y: 28), c.onSurfaceVariant),
            say(String(localized: "Notifications"), .bodyLarge, x: 56, top: 16, c.onSurface, name: "Headline"),
            P.group("Switch", switchNodes(c, on: true)).moved(w - 16 - 52, 12),
        ])
    }

    static let twoLineListItem = Component(id: "android.two-line-list-item", title: "Two-Line List Item", size: CGSize(width: 412, height: 72), fit: .across(margin: 0), minWidth: 320) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([
            P.rect("Background", P.box(0, 0, w, 72), c.surface),
            avatar(c, center: CGPoint(x: 36, y: 36), diameter: 40, initial: "A"),
            say("Alex Morgan", .bodyLarge, x: 72, top: 14, c.onSurface, name: "Headline"),
            say(String(localized: "Are we still on for lunch?"), .bodyMedium, x: 72, top: 38, c.onSurfaceVariant, name: "Supporting Text"),
            say(String(localized: "10 min"), .labelSmall, x: w - 16, top: 28, c.onSurfaceVariant, align: .right, name: "Trailing Text"),
        ])
    }

    static let threeLineListItem = Component(id: "android.three-line-list-item", title: "Three-Line List Item", size: CGSize(width: 412, height: 88), fit: .across(margin: 0), minWidth: 320) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([
            P.rect("Background", P.box(0, 0, w, 88), c.surface),
            media(c, P.box(16, 16, 56, 56), corners: [8, 8, 8, 8], sign: 24),
            say(String(localized: "Weekend Plans"), .bodyLarge, x: 88, top: 12, c.onSurface, name: "Headline"),
            prose(String(localized: "Shall we take the early train on Saturday morning?"), .bodyMedium, x: 88, top: 36, width: w - 88 - 56,
                  c.onSurfaceVariant, name: "Supporting Text"),
            P.group("Checkbox", checkboxNodes(c, checked: true)).moved(w - 16 - 21, 15),
        ])
    }

    static let dialog = fixed("android.dialog", "Dialog") { look in
        let c = Palette(dark: look.dark), w: CGFloat = 312
        let text = prose(String(localized: "This draft will be removed from all your synced devices."), .bodyMedium,
                         x: 24, top: 112, width: w - 48, c.onSurfaceVariant, name: "Supporting Text")
        let top = text.frame.maxY + 24
        let confirm = button(String(localized: "Delete"), .text, c), dismiss = button(String(localized: "Cancel"), .text, c)
        let h = top + 40 + 24
        return P.part([
            P.rect("Background", P.box(0, 0, w, h), c.surfaceContainerHigh, radius: 28),
            symbol("delete", center: CGPoint(x: w / 2, y: 36), c.secondary),
            say(String(localized: "Delete draft?"), .headlineSmall, x: w / 2, top: 64, c.onSurface, align: .center, name: "Headline"),
            text,
            P.group("Actions", [
                dismiss.moved(w - 24 - confirm.frame.width - 8 - dismiss.frame.width, top),
                confirm.moved(w - 24 - confirm.frame.width, top),
            ]),
        ])
    }

    static let bottomSheet = Component(id: "android.bottom-sheet", title: "Bottom Sheet", size: CGSize(width: 412, height: 280), fit: .bottom, minWidth: 320) { look in
        let c = Palette(dark: look.dark), w = look.width
        let items: [(String, String)] = [("share", String(localized: "Share")), ("link", String(localized: "Copy link")),
                                         ("edit", String(localized: "Rename")), ("delete", String(localized: "Delete"))]
        let rows = items.enumerated().map { i, item in
            let y = 48 + 56 * CGFloat(i)
            return P.group(item.1, [
                symbol(item.0, center: CGPoint(x: 28, y: y + 28), c.onSurfaceVariant),
                say(item.1, .bodyLarge, x: 56, top: y + 16, c.onSurface, name: "Label"),
            ])
        }
        return P.part([
            P.rect("Background", P.box(0, 0, w, 280), c.surfaceContainerLow, corners: [28, 28, 0, 0]),
            P.pill("Drag Handle", P.box(((w - 32) / 2).rounded(), 22, 32, 4), c.onSurfaceVariant.with(alpha: 0.4)),
            P.group("Items", rows),
        ])
    }

    static let navigationDrawer = fixed("android.navigation-drawer", "Navigation Drawer") { look in
        let c = Palette(dark: look.dark), w: CGFloat = 360
        func item(_ icon: String, _ label: String, y: CGFloat, on: Bool = false, badge: String? = nil) -> Node {
            let ink = on ? c.onSecondaryContainer : c.onSurfaceVariant
            var nodes: [Node] = []
            if on { nodes.append(P.pill("Indicator", P.box(12, y, w - 24, 56), c.secondaryContainer)) }
            nodes.append(symbol(icon, center: CGPoint(x: 40, y: y + 28), ink, filled: on))
            nodes.append(say(label, .labelLarge, x: 64, top: y + 18, ink, name: "Label"))
            if let badge { nodes.append(say(badge, .labelLarge, x: w - 36, top: y + 18, ink, align: .right, name: "Badge")) }
            return P.group(label, nodes)
        }
        let mail: [(String, String)] = [("inbox", String(localized: "Inbox")), ("outbox", String(localized: "Outbox")),
                                        ("favorite", String(localized: "Favorites")), ("delete", String(localized: "Trash"))]
        let labels = [String(localized: "Family"), String(localized: "School"), String(localized: "Work")]
        let second: CGFloat = 68 + 56 * 4 + 17
        let h = second + 56 + 56 * 3 + 12
        return P.part([
            P.rect("Background", P.box(0, 0, w, h), c.surfaceContainerLow, corners: [0, 16, 16, 0]),
            say(String(localized: "Mail"), .titleSmall, x: 28, top: 30, c.onSurfaceVariant, name: "Headline"),
            P.group("Mail", mail.enumerated().map { i, m in
                item(m.0, m.1, y: 68 + 56 * CGFloat(i), on: i == 0, badge: i == 0 ? "24" : nil)
            }),
            P.rule("Divider", x: 28, y: 68 + 56 * 4 + 8, width: w - 56, c.outlineVariant, thickness: 1),
            say(String(localized: "Labels"), .titleSmall, x: 28, top: second + 18, c.onSurfaceVariant, name: "Section Header"),
            P.group("Labels", labels.enumerated().map { i, label in
                item("label", label, y: second + 56 + 56 * CGFloat(i))
            }),
        ])
    }

    static let menu = fixed("android.menu", "Menu") { look in
        let c = Palette(dark: look.dark), w: CGFloat = 200
        func item(_ icon: String, _ label: String, y: CGFloat) -> Node {
            P.group(label, [
                symbol(icon, center: CGPoint(x: 24, y: y + 24), c.onSurfaceVariant),
                say(label, .labelLarge, x: 48, top: y + 14, c.onSurface, name: "Label"),
            ])
        }
        let items: [(String, String)] = [("edit", String(localized: "Edit")), ("share", String(localized: "Share")),
                                         ("link", String(localized: "Copy link"))]
        let last: CGFloat = 8 + 48 * 3 + 17
        return P.part([
            P.rect("Background", P.box(0, 0, w, last + 48 + 8), c.surfaceContainer, radius: 16).raised(2),
            P.group("Items", items.enumerated().map { i, it in item(it.0, it.1, y: 8 + 48 * CGFloat(i)) }
                + [P.rule("Divider", x: 0, y: 8 + 48 * 3 + 8, width: w, c.outlineVariant, thickness: 1),
                   item("delete", String(localized: "Delete"), y: last)]),
        ])
    }

    static let divider = Component(id: "android.divider", title: "Divider", size: CGSize(width: 412, height: 1), fit: .across(margin: 0), minWidth: 40) { look in
        P.part([P.rect("Divider", P.box(0, 0, look.width, 1), Palette(dark: look.dark).outlineVariant)])
    }

    // MARK: - Feedback

    static let snackbar = Component(id: "android.snackbar", title: "Snackbar", size: CGSize(width: 380, height: 48), fit: .across(margin: 16), minWidth: 240) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([
            P.rect("Background", P.box(0, 0, w, 48), c.inverseSurface, radius: 4).raised(3),
            say(String(localized: "Message archived"), .bodyMedium, x: 16, top: 14, c.inverseOnSurface, name: "Message"),
            say(String(localized: "Undo"), .labelLarge, x: w - 20, top: 14, c.inversePrimary, align: .right, name: "Action"),
        ])
    }

    static let badge = fixed("android.badge", "Badge") { look in
        let c = Palette(dark: look.dark), label = "12"
        let w = max(16, measure(label, .labelSmall) + 8)
        return P.part([
            P.pill("Background", P.box(0, 0, w, 16), c.error),
            say(label, .labelSmall, x: w / 2, top: 0, c.onError, align: .center, name: "Label"),
        ])
    }

    static let linearProgress = Component(id: "android.linear-progress", title: "Linear Progress Indicator", size: CGSize(width: 380, height: 4), fit: .across(margin: 16), minWidth: 80) { look in
        let c = Palette(dark: look.dark), w = look.width
        let done = (w * 0.6).rounded()
        return P.part([
            P.rect("Active Indicator", P.box(0, 0, done, 4), c.primary, radius: 2),
            P.rect("Track", P.box(done + 4, 0, w - done - 4, 4), c.secondaryContainer, radius: 2),
            P.rect("Stop Indicator", P.box(w - 4, 0, 4, 4), c.primary, radius: 2),
        ])
    }

    static let circularProgress = Component(id: "android.circular-progress", title: "Circular Progress Indicator", size: CGSize(width: 48, height: 48)) { look in
        let c = Palette(dark: look.dark)
        let box = P.box(0, 0, 48, 48), mid = CGPoint(x: 24, y: 24), r: CGFloat = 22
        // The gap between the two is four points of their circle, past their round ends.
        let gap = (4 + 4) / r * 180 / .pi, end: CGFloat = -90 + 360 * 0.65
        return P.part([
            P.frame(48, 48),
            P.shape("Track", arc(center: mid, radius: r, width: 4, from: end + gap, to: 270 - gap), box: box, in: box, c.secondaryContainer),
            P.shape("Active Indicator", arc(center: mid, radius: r, width: 4, from: -90, to: end), box: box, in: box, c.primary),
        ])
    }
}

nonisolated private extension Node {
    /// The same layer lifted to an M3 elevation level.
    func raised(_ level: Int) -> Node {
        var n = self
        n.shadows = AndroidKit.elevation(level)
        return n
    }
}
