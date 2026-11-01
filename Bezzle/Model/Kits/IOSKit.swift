import Foundation
import CoreGraphics

private typealias P = Parts

/// iOS 26 as it looks now: Liquid Glass bars and buttons floating over the content, SF Pro, the
/// system colours of 2025 and continuous corners. Symbols are the nearest of Lucide's lines and
/// Phosphor's filled shapes, drawn at the sizes and weights SF Symbols take beside SF Pro.
/// Measured on a 402-point iPhone, against Apple's own drawings of iOS 26.
nonisolated enum IOSKit {
    static let kit = Kit(id: "ios", title: "iOS", paper: .hex("#F2F2F7"), darkPaper: .black, sections: [
        KitSection(title: "Bars", components: [statusBar, navigationBarLarge, navigationBar, tabBar, tabBarWithSearch, tabBarWithAccessory, toolbar,
                                               searchBar, homeIndicator]),
        KitSection(title: "Controls", components: [toggle, toggleOff, buttonProminent, buttonTinted, buttonGlass, buttonSmall,
                                                   buttonGlassIcon, buttonDone, segmentedControl, slider, stepper, pageControl,
                                                   progressBar, activityIndicator]),
        KitSection(title: "Lists", components: [sectionHeader, listSection, listSectionValues, contactRow, disclosureRow, detailRow,
                                                sectionFooter]),
        KitSection(title: "Text Fields", components: [textField, textFieldFilled, searchField]),
        KitSection(title: "Alerts and Menus", components: [alert, actionSheet, contextMenu, notification, sheetHeader]),
        KitSection(title: "Keyboard", components: [keyboard]),
    ])

    /// The system's colours, light or dark, as iOS 26 has them.
    struct Palette {
        let dark: Bool
        private func pick(_ light: String, _ dark: String) -> RGBA { .hex(self.dark ? dark : light) }

        var label: RGBA { dark ? .white : .black }
        var secondary: RGBA { pick("#3C3C4399", "#EBEBF599") }
        var tertiary: RGBA { pick("#3C3C434D", "#EBEBF54D") }
        var blue: RGBA { pick("#0088FF", "#0091FF") }
        var green: RGBA { pick("#34C759", "#30D158") }
        var red: RGBA { pick("#FF383C", "#FF4245") }
        var orange: RGBA { pick("#FF8D28", "#FF9230") }
        var gray: RGBA { .hex("#8E8E93") }
        /// systemFill, secondarySystemFill and tertiarySystemFill: greys that let what lies under them show.
        var fill: RGBA { pick("#78788033", "#7878805C") }
        var fill2: RGBA { pick("#78788029", "#78788052") }
        var fill3: RGBA { pick("#7676801F", "#7676803D") }
        var background: RGBA { dark ? .black : .white }
        /// A row of a grouped list, and a sheet.
        var cell: RGBA { pick("#FFFFFF", "#1C1C1E") }
        var separator: RGBA { pick("#3C3C434A", "#54545899") }
        var grabber: RGBA { pick("#3C3C4340", "#EBEBF540") }
        /// Liquid Glass: a pale or dark tint over what lies behind, blurred, its edge catching the light.
        var glass: RGBA { pick("#F7F7F7D6", "#202020D6") }
        var glassRim: RGBA { pick("#FFFFFFD9", "#FFFFFF2E") }
        var glassEdge: RGBA { pick("#0000001A", "#0000008C") }
        var glassShade: RGBA { pick("#00000012", "#FFFFFF12") }
        var glassShadow: RGBA { pick("#00000014", "#00000066") }
        /// The thicker glass of an alert, a menu or a notification.
        var panel: RGBA { pick("#FAFAFAEB", "#1E1E1EEB") }
        /// What an alert's message is written in, darker than secondary on the glass.
        var message: RGBA { pick("#000000B3", "#FFFFFFB3") }
        /// The lighter glass of the selected tab.
        var platter: RGBA { pick("#FFFFFF", "#FFFFFF1A") }
    }

    // MARK: - Bars

    static let statusBar = Component(id: "ios.status-bar", title: "Status Bar", size: CGSize(width: 402, height: 54), fit: .top, minWidth: 320) { look in
        let c = Palette(dark: look.dark), w = look.width
        // The time sits in the left ear beside the Dynamic Island, the signs in the right one,
        // both on the island's middle.
        let ear = (w - 126) / 2
        let right = w - ear / 2 + 32.25
        let bottom: CGFloat = 38.25
        var battery: [Node] = []
        battery.append(P.rect("Level", P.box(right - 26.5, bottom - 12, 24.5, 12), c.label, radius: 3.8, smooth: true))
        battery.append(P.rect("Cap", P.box(right - 0.8, bottom - 8, 1.6, 4), c.label.with(alpha: 0.5), corners: [0, 1, 1, 0]))
        let wifiRight = right - 26.5 - 7
        var bars: [Node] = []
        let heights: [CGFloat] = [4.8, 7.2, 9.6, 12]
        let cellRight = wifiRight - 17.5 - 7
        for (i, h) in heights.enumerated() {
            bars.append(P.rect("Bar \(i + 1)", P.box(cellRight - 19 + CGFloat(i) * 5.25, bottom - h, 3.25, h), c.label, radius: 1))
        }
        return P.part([
            P.frame(w, 54),
            words("9:41", name: "Time", x: (ear / 2 + 3.75).rounded(), baseline: 39, size: 17, weight: "Semibold", c.label, align: .center),
            P.group("Cellular", bars),
            wifi(right: wifiRight, bottom: bottom, c.label),
            P.group("Battery", battery),
        ])
    }

    static let navigationBarLarge = Component(id: "ios.navigation-bar-large", title: "Navigation Bar, Large Title",
                                              size: CGSize(width: 402, height: 96), fit: .top, minWidth: 320) { look in
        let c = Palette(dark: look.dark), w = look.width
        let add = glassCircle("Add", center: CGPoint(x: w - 38, y: 22), diameter: 44, symbol: "plus", size: 18, c)
        let group = itemGroup(["search", "ellipsis"], right: w - 16 - 44 - 8, c)
        return P.part([
            P.frame(w, 96),
            P.group("Trailing Items", [group, add]),
            words(String(localized: "Library"), name: "Title", x: 16, baseline: 85, size: 34, weight: "Bold", c.label),
        ])
    }

    static let navigationBar = Component(id: "ios.navigation-bar", title: "Navigation Bar", size: CGSize(width: 402, height: 44),
                                         fit: .top, minWidth: 320) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([
            P.frame(w, 44),
            glassCircle("Back", center: CGPoint(x: 38, y: 22), diameter: 44, symbol: "chevron-left", size: 18, stroke: 2, c, nudge: -1),
            centered(String(localized: "Details"), name: "Title", x: w / 2, y: 22, size: 17, weight: "Semibold", c.label),
            textButton("Edit", String(localized: "Edit"), right: w - 16, y: 0, height: 44, c),
        ])
    }

    static let tabBar = Component(id: "ios.tab-bar", title: "Tab Bar", size: CGSize(width: 402, height: 83), fit: .bottom, minWidth: 320) { look in
        let c = Palette(dark: look.dark), w = look.width
        let bar = P.box(21, 0, w - 42, 62)
        return P.part([
            P.frame(w, 83),
            P.group("Tab Bar", [glass("Glass", bar, c)] + tabs(standardTabs, in: bar, badge: 2, c)),
            homeBar(w, bottom: 83, c),
        ])
    }

    static let tabBarWithSearch = Component(id: "ios.tab-bar-search", title: "Tab Bar with Search", size: CGSize(width: 402, height: 83),
                                            fit: .bottom, minWidth: 320) { look in
        let c = Palette(dark: look.dark), w = look.width
        let bar = P.box(21, 0, w - 42 - 62 - 8, 62)
        return P.part([
            P.frame(w, 83),
            P.group("Tab Bar", [glass("Glass", bar, c)] + tabs(Array(standardTabs.prefix(3)), in: bar, badge: nil, c)),
            glassCircle("Search", center: CGPoint(x: w - 52, y: 31), diameter: 62, symbol: "search", size: 21, c),
            homeBar(w, bottom: 83, c),
        ])
    }

    static let tabBarWithAccessory = Component(id: "ios.tab-bar-accessory", title: "Tab Bar with Accessory", size: CGSize(width: 402, height: 139),
                                               fit: .bottom, minWidth: 320) { look in
        let c = Palette(dark: look.dark), w = look.width
        // What is playing, on its own glass over the tabs, as Music has it.
        let strip = P.box(21, 0, w - 42, 48)
        let art = P.rect("Background", P.box(31, 8, 32, 32), look.dark ? .hex("#3A3A3C") : .hex("#E5E5EA"), radius: 7, smooth: true)
        let accessory = P.group("Accessory", [
            glass("Glass", strip, c),
            P.group("Artwork", [art, filled("music-note", center: CGPoint(x: 47, y: 24), size: 17, c.tertiary)]),
            centered(String(localized: "Not Playing"), name: "Title", x: 73, y: 24, size: 15, weight: "Semibold", c.label, align: .left),
            filled("play", center: CGPoint(x: w - 99, y: 24), size: 18, c.label),
            filled("fast-forward", center: CGPoint(x: w - 51, y: 24), size: 25, c.secondary),
        ])
        let bar = P.box(21, 56, w - 42, 62)
        return P.part([
            P.frame(w, 139),
            accessory,
            P.group("Tab Bar", [glass("Glass", bar, c)] + tabs(standardTabs, in: bar, badge: nil, c)),
            homeBar(w, bottom: 139, c),
        ])
    }

    static let toolbar = Component(id: "ios.toolbar", title: "Toolbar", size: CGSize(width: 402, height: 76), fit: .bottom, minWidth: 320) { look in
        let c = Palette(dark: look.dark), w = look.width
        // A group of tools on one glass, and the main action on its own, as Notes has them.
        let tools = ["list-checks", "camera", "paperclip"]
        let slot: CGFloat = 54, pad: CGFloat = 6
        let capsule = P.box(21, 0, slot * CGFloat(tools.count) + pad * 2, 48)
        var group: [Node] = [glass("Glass", capsule, c)]
        for (i, name) in tools.enumerated() {
            group.append(symbol(name, center: CGPoint(x: capsule.minX + pad + slot * (CGFloat(i) + 0.5), y: 24), size: 21, c.label))
        }
        return P.part([
            P.frame(w, 76),
            P.group("Tools", group),
            glassCircle("Compose", center: CGPoint(x: w - 45, y: 24), diameter: 48, symbol: "square-pen", size: 21, c),
            homeBar(w, bottom: 76, c),
        ])
    }

    static let searchBar = Component(id: "ios.search-bar", title: "Search Bar", size: CGSize(width: 370, height: 48),
                                     fit: .across(margin: 16), minWidth: 200) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([
            glass("Glass", P.box(0, 0, w, 48), c),
            symbol("search", center: CGPoint(x: 27, y: 24), size: 19, c.secondary),
            centered(String(localized: "Search"), name: "Placeholder", x: 46, y: 24, size: 17, c.secondary, align: .left),
            symbol("mic", center: CGPoint(x: w - 26, y: 24), size: 19, c.secondary),
        ])
    }

    static let homeIndicator = Component(id: "ios.home-indicator", title: "Home Indicator", size: CGSize(width: 402, height: 34),
                                         fit: .bottom, minWidth: 320) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([P.frame(w, 34), homeBar(w, bottom: 34, c)])
    }

    // MARK: - Controls

    static let toggle = Component(id: "ios.toggle", title: "Toggle, On", size: CGSize(width: 64, height: 28)) { look in
        switchControl(on: true, Palette(dark: look.dark))
    }

    static let toggleOff = Component(id: "ios.toggle-off", title: "Toggle, Off", size: CGSize(width: 64, height: 28)) { look in
        switchControl(on: false, Palette(dark: look.dark))
    }

    static let buttonProminent = Component(id: "ios.button-prominent", title: "Button, Prominent", size: CGSize(width: 370, height: 50),
                                           fit: .across(margin: 16), minWidth: 120) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([
            P.pill("Background", P.box(0, 0, w, 50), c.blue),
            centered(String(localized: "Continue"), name: "Label", x: w / 2, y: 25, size: 17, weight: "Semibold", .white),
        ])
    }

    static let buttonTinted = Component(id: "ios.button-tinted", title: "Button, Tinted", size: CGSize(width: 370, height: 50),
                                        fit: .across(margin: 16), minWidth: 120) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([
            P.pill("Background", P.box(0, 0, w, 50), c.blue.with(alpha: look.dark ? 0.2 : 0.14)),
            centered(String(localized: "Learn More"), name: "Label", x: w / 2, y: 25, size: 17, weight: "Semibold", c.blue),
        ])
    }

    static let buttonGlass = fixed("ios.button-glass", "Button, Glass") { look in
        let c = Palette(dark: look.dark)
        let label = String(localized: "Share")
        let width = (18 + 20 + 7 + P.width(of: label, size: 17, weight: "Medium") + 20).rounded()
        return P.part([
            glass("Glass", P.box(0, 0, width, 48), c),
            symbol("share", center: CGPoint(x: 28, y: 23), size: 20, c.label),
            centered(label, name: "Label", x: 45, y: 24, size: 17, weight: "Medium", c.label, align: .left),
        ])
    }

    static let buttonSmall = fixed("ios.button-small", "Button, Small") { look in
        let c = Palette(dark: look.dark)
        let label = String(localized: "Get")
        let width = max(74, (P.width(of: label, size: 15, weight: "Bold") + 36).rounded())
        return P.part([
            P.pill("Background", P.box(0, 0, width, 30), c.fill2),
            centered(label, name: "Label", x: width / 2, y: 15, size: 15, weight: "Bold", c.blue),
        ])
    }

    static let buttonGlassIcon = Component(id: "ios.button-glass-icon", title: "Button, Glass Icon", size: CGSize(width: 44, height: 44)) { look in
        let c = Palette(dark: look.dark)
        return P.part([glassCircle("Button", center: CGPoint(x: 22, y: 22), diameter: 44, symbol: "ellipsis", size: 20, c)])
    }

    static let buttonDone = Component(id: "ios.button-done", title: "Button, Done", size: CGSize(width: 44, height: 44)) { look in
        let c = Palette(dark: look.dark)
        return P.part([doneButton(at: CGPoint(x: 0, y: 0), c)])
    }

    static let segmentedControl = Component(id: "ios.segmented-control", title: "Segmented Control", size: CGSize(width: 370, height: 32),
                                            fit: .across(margin: 16), minWidth: 200) { look in
        let c = Palette(dark: look.dark), w = look.width
        let labels = [String(localized: "Day"), String(localized: "Week"), String(localized: "Month")]
        let segment = w / CGFloat(labels.count)
        var items: [Node] = []
        for (i, label) in labels.enumerated() {
            items.append(centered(label, x: segment * (CGFloat(i) + 0.5), y: 16, size: 13, weight: i == 0 ? "Semibold" : "Medium", c.label))
        }
        let thumb = P.pill("Thumb", P.box(3, 3, segment - 6, 26), look.dark ? .hex("#636366") : .white)
            .casting(P.shadow(y: 2, blur: 6, .hex(look.dark ? "#00000040" : "#0000001A")))
        return P.part([
            P.pill("Track", P.box(0, 0, w, 32), c.fill3),
            thumb,
            P.group("Labels", items),
        ])
    }

    static let slider = Component(id: "ios.slider", title: "Slider", size: CGSize(width: 370, height: 28), fit: .across(margin: 16), minWidth: 80) { look in
        let c = Palette(dark: look.dark), w = look.width
        let x = ((w - 24) * 0.6).rounded()
        return P.part([
            P.frame(w, 28),
            P.pill("Track", P.box(0, 11, w, 6), c.fill3),
            P.pill("Fill", P.box(0, 11, x + 12, 6), c.blue),
            P.pill("Thumb", P.box(x, 4, 24, 20), .white)
                .casting(P.shadow(y: 2, blur: 8, .hex("#00000029")), P.shadow(y: 0, blur: 1, .hex("#0000001A"))),
        ])
    }

    static let stepper = Component(id: "ios.stepper", title: "Stepper", size: CGSize(width: 94, height: 32)) { look in
        let c = Palette(dark: look.dark)
        return P.part([
            P.pill("Background", P.box(0, 0, 94, 32), c.fill3),
            symbol("minus", center: CGPoint(x: 23.5, y: 16), size: 15, stroke: 1.9, c.label),
            P.rect("Divider", P.box(46.75, 8, 0.5, 16), c.separator),
            symbol("plus", center: CGPoint(x: 70.5, y: 16), size: 15, stroke: 1.9, c.label),
        ])
    }

    static let pageControl = Component(id: "ios.page-control", title: "Page Control", size: CGSize(width: 96, height: 26)) { look in
        let c = Palette(dark: look.dark)
        var dots: [Node] = []
        for i in 0..<5 {
            dots.append(P.circle("Page \(i + 1)", center: CGPoint(x: 16 + CGFloat(i) * 16, y: 13), radius: 4,
                                 i == 0 ? c.label : c.label.with(alpha: 0.3)))
        }
        return P.part([P.frame(96, 26), P.group("Pages", dots)])
    }

    static let progressBar = Component(id: "ios.progress-bar", title: "Progress Bar", size: CGSize(width: 370, height: 4),
                                       fit: .across(margin: 16), minWidth: 60) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([
            P.pill("Track", P.box(0, 0, w, 4), c.fill3),
            P.pill("Progress", P.box(0, 0, (w * 0.4).rounded(), 4), c.blue),
        ])
    }

    static let activityIndicator = Component(id: "ios.activity-indicator", title: "Activity Indicator", size: CGSize(width: 20, height: 20)) { look in
        let c = Palette(dark: look.dark)
        // Eight spokes turning clockwise, the one at the top the darkest, those behind it fading.
        let fades: [Double] = [1, 0.9, 0.78, 0.66, 0.54, 0.44, 0.36, 0.3]
        var spokes: [Node] = []
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4
            let center = CGPoint(x: 10 + 6.6 * sin(angle), y: 10 - 6.6 * cos(angle))
            var spoke = P.pill("Spoke \(i + 1)", P.box(center.x - 1.25, center.y - 2.9, 2.5, 5.8), c.gray.with(alpha: fades[(8 - i) % 8]))
            spoke.rotation = Double(i) * 45
            spokes.append(spoke)
        }
        return P.part([P.frame(20, 20), P.group("Spokes", spokes)])
    }

    // MARK: - Lists

    static let sectionHeader = Component(id: "ios.section-header", title: "Section Header", size: CGSize(width: 370, height: 36),
                                         fit: .across(margin: 16), minWidth: 160) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([
            P.frame(w, 36),
            words(String(localized: "Connections").uppercased(), name: "Title", x: 16, baseline: 27, size: 13, c.secondary),
        ])
    }

    static let listSection = Component(id: "ios.list-section", title: "List Section", size: CGSize(width: 370, height: 208),
                                       fit: .across(margin: 16), minWidth: 280) { look in
        let c = Palette(dark: look.dark), w = look.width
        let rows: [Node] = [
            row(0, "Airplane Mode", icon: .filled("airplane"), tint: c.orange, String(localized: "Airplane Mode"), trailing: .toggle(false), w, c),
            row(1, "Wi-Fi", icon: .line("wifi"), tint: c.blue, String(localized: "Wi-Fi"), trailing: .value("Studio"), w, c),
            row(2, "Bluetooth", icon: .line("bluetooth"), tint: c.blue, String(localized: "Bluetooth"), trailing: .value(String(localized: "On")), w, c),
            row(3, "Cellular", icon: .line("radio-tower"), tint: c.green, String(localized: "Cellular"), trailing: .chevron, w, c, last: true),
        ]
        return P.part([P.rect("Background", P.box(0, 0, w, 208), c.cell, radius: 26, smooth: true)] + rows)
    }

    static let listSectionValues = Component(id: "ios.list-section-values", title: "List Section, Values", size: CGSize(width: 370, height: 208),
                                             fit: .across(margin: 16), minWidth: 280) { look in
        let c = Palette(dark: look.dark), w = look.width
        let rows: [Node] = [
            row(0, "Name", icon: nil, tint: nil, String(localized: "Name"), trailing: .value("iPhone"), w, c),
            row(1, "Software Version", icon: nil, tint: nil, String(localized: "Software Version"), trailing: .plain("26.1"), w, c),
            row(2, "Model Name", icon: nil, tint: nil, String(localized: "Model Name"), trailing: .plain("iPhone 17 Pro"), w, c),
            row(3, "Storage", icon: nil, tint: nil, String(localized: "Storage"), trailing: .value("256 GB"), w, c, last: true),
        ]
        return P.part([P.rect("Background", P.box(0, 0, w, 208), c.cell, radius: 26, smooth: true)] + rows)
    }

    static let contactRow = Component(id: "ios.contact-row", title: "Contact Row", size: CGSize(width: 402, height: 72),
                                      fit: .across(margin: 0), minWidth: 280) { look in
        let c = Palette(dark: look.dark), w = look.width
        var avatar = P.circle("Avatar", center: CGPoint(x: 38, y: 36), radius: 22, .hex("#A5ABB8"))
        avatar.fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: .hex("#A5ABB8")),
                                                               GradientStop(offset: 1, color: .hex("#858994"))],
                                        start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1))
        let time = words("9:41", name: "Time", x: w - 34, baseline: 32, size: 15, c.secondary, align: .right)
        return P.part([
            P.rect("Background", P.box(0, 0, w, 72), c.background),
            P.group("Avatar", [avatar, centered("AT", name: "Initials", x: 38, y: 36, size: 18, weight: "Semibold", .white)]),
            words("Ava Thompson", name: "Name", x: 72, baseline: 32, size: 17, weight: "Semibold", c.label),
            words(String(localized: "Running a few minutes late"), name: "Message", x: 72, baseline: 53, size: 15, c.secondary),
            time,
            symbol("chevron-right", center: CGPoint(x: w - 20, y: 27), size: 11, stroke: 2, c.tertiary),
            P.rule(x: 72, y: 71.5, width: w - 72, c.separator),
        ])
    }

    static let disclosureRow = Component(id: "ios.disclosure-row", title: "Disclosure Row", size: CGSize(width: 370, height: 52),
                                         fit: .across(margin: 16), minWidth: 200) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([P.rect("Background", P.box(0, 0, w, 52), c.cell, radius: 26, smooth: true),
                       row(0, "Notifications", icon: nil, tint: nil, String(localized: "Notifications"), trailing: .chevron, w, c, last: true)])
    }

    static let detailRow = Component(id: "ios.detail-row", title: "Detail Row", size: CGSize(width: 370, height: 64),
                                     fit: .across(margin: 16), minWidth: 200) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([
            P.rect("Background", P.box(0, 0, w, 64), c.cell, radius: 26, smooth: true),
            P.group("Row", [
                words("Ava Thompson", name: "Title", x: 16, baseline: 28, size: 17, c.label),
                words(String(localized: "Mobile"), name: "Subtitle", x: 16, baseline: 48, size: 15, c.secondary),
                symbol("info", center: CGPoint(x: w - 27, y: 32), size: 22, stroke: 1.7, c.blue),
            ]),
        ])
    }

    static let sectionFooter = Component(id: "ios.section-footer", title: "Section Footer", size: CGSize(width: 370, height: 56),
                                         fit: .across(margin: 16), minWidth: 200) { look in
        let c = Palette(dark: look.dark), w = look.width
        let text = P.paragraph(String(localized: "Known networks are joined automatically. If none is available, you will be asked before joining a new one."),
                               name: "Footer", x: 16, y: 7, width: w - 32, size: 13, color: c.secondary, line: 18)
        return P.part([P.frame(w, max(56, text.frame.maxY + 13)), text])
    }

    // MARK: - Text Fields

    static let textField = Component(id: "ios.text-field", title: "Text Field", size: CGSize(width: 370, height: 52),
                                     fit: .across(margin: 16), minWidth: 160) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([
            P.rect("Background", P.box(0, 0, w, 52), c.cell, radius: 26, smooth: true),
            centered(String(localized: "Email Address"), name: "Placeholder", x: 16, y: 26, size: 17, c.tertiary, align: .left),
        ])
    }

    static let textFieldFilled = Component(id: "ios.text-field-filled", title: "Text Field, Filled", size: CGSize(width: 370, height: 52),
                                           fit: .across(margin: 16), minWidth: 240) { look in
        let c = Palette(dark: look.dark), w = look.width
        let text = centered("ava@example.com", name: "Text", x: 16, y: 26, size: 17, c.label, align: .left)
        return P.part([
            P.rect("Background", P.box(0, 0, w, 52), c.cell, radius: 26, smooth: true),
            text,
            P.rect("Caret", P.box(text.frame.maxX + 1, 15, 2, 22), c.blue, radius: 1),
            filled("x-circle", center: CGPoint(x: w - 26, y: 26), size: 18, c.tertiary),
        ])
    }

    static let searchField = Component(id: "ios.search-field", title: "Search Field", size: CGSize(width: 370, height: 36),
                                       fit: .across(margin: 16), minWidth: 160) { look in
        let c = Palette(dark: look.dark), w = look.width
        return P.part([
            P.pill("Background", P.box(0, 0, w, 36), c.fill3),
            symbol("search", center: CGPoint(x: 20, y: 18), size: 16, stroke: 1.9, c.secondary),
            centered(String(localized: "Search"), name: "Placeholder", x: 35, y: 18, size: 17, c.secondary, align: .left),
            symbol("mic", center: CGPoint(x: w - 19, y: 18), size: 17, stroke: 1.8, c.secondary),
        ])
    }

    // MARK: - Alerts and Menus

    static let alert = fixed("ios.alert", "Alert") { look in
        let c = Palette(dark: look.dark)
        let w: CGFloat = 300
        let title = words(String(localized: "Turn On Notifications?"), name: "Title", x: 22, baseline: 39, size: 17, weight: "Semibold", c.label)
        var message = P.paragraph(String(localized: "Get a notification when someone shares a photo with you."), name: "Message",
                                  x: 22, y: 0, width: w - 44, size: 17, color: c.message, line: 22)
        message.frame.origin.y = (71 - TextLayout.firstBaseline(message)).rounded()
        let top = (message.frame.maxY + 24).rounded()
        let half = (w - 28 - 8) / 2
        let buttons = P.group("Buttons", [
            P.group("Not Now", [P.pill("Background", P.box(14, top, half, 48), c.fill2),
                                                   centered(String(localized: "Not Now"), name: "Label", x: 14 + half / 2, y: top + 24, size: 17, weight: "Medium", c.label)]),
            P.group("Turn On", [P.pill("Background", P.box(22 + half, top, half, 48), c.blue),
                                                   centered(String(localized: "Turn On"), name: "Label", x: 22 + half * 1.5, y: top + 24, size: 17, weight: "Semibold", .white)]),
        ])
        return P.part([panel("Background", P.box(0, 0, w, top + 62), radius: 34, c), title, message, buttons])
    }

    static let actionSheet = fixed("ios.action-sheet", "Action Sheet") { look in
        let c = Palette(dark: look.dark)
        let w: CGFloat = 250
        let actions: [(String, String, RGBA)] = [("Delete Draft", String(localized: "Delete Draft"), c.red),
                                                 ("Save Draft", String(localized: "Save Draft"), c.label)]
        var buttons: [Node] = []
        for (i, (name, label, color)) in actions.enumerated() {
            let y = 14 + CGFloat(i) * 58
            buttons.append(P.group(name, [P.pill("Background", P.box(14, y, w - 28, 48), c.fill2),
                                           centered(label, name: "Label", x: w / 2, y: y + 24, size: 17, weight: "Medium", color)]))
        }
        return P.part([panel("Background", P.box(0, 0, w, 14 + 58 * CGFloat(actions.count) - 10 + 14), radius: 38, c),
                       P.group("Buttons", buttons)])
    }

    static let contextMenu = fixed("ios.context-menu", "Context Menu") { look in
        let c = Palette(dark: look.dark)
        let w: CGFloat = 250
        let items: [(String, String, String, RGBA)] = [
            ("copy", "Copy", String(localized: "Copy"), c.label),
            ("share", "Share", String(localized: "Share"), c.label),
            ("heart", "Add to Favorites", String(localized: "Add to Favorites"), c.label),
            ("trash", "Delete", String(localized: "Delete"), c.red),
        ]
        var rows: [Node] = []
        var y: CGFloat = 10
        for (i, (icon, name, label, color)) in items.enumerated() {
            if i == 3 {
                rows.append(P.rule(x: 20, y: y + 6, width: w - 40, c.separator))
                y += 12.5
            }
            rows.append(P.group(name, [
                symbol(icon, center: CGPoint(x: 31, y: y + 22), size: 19, stroke: 1.7, color),
                centered(label, name: "Label", x: 58, y: y + 22, size: 17, color, align: .left),
            ]))
            y += 44
        }
        return P.part([panel("Background", P.box(0, 0, w, y + 10), radius: 30, c), P.group("Items", rows)])
    }

    static let notification = Component(id: "ios.notification", title: "Notification", size: CGSize(width: 382, height: 86),
                                        fit: .across(margin: 10), minWidth: 280) { look in
        let c = Palette(dark: look.dark), w = look.width
        var tile = P.rect("Background", P.box(14, 0, 38, 38), .hex("#34C759"), radius: 9, smooth: true)
        tile.fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: .hex("#6BF07F")),
                                                             GradientStop(offset: 1, color: .hex("#0BBD2C"))],
                                      start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1))
        var body = P.paragraph(String(localized: "Are we still on for lunch tomorrow? I found a great new place nearby."), name: "Message",
                               x: 62, y: 0, width: w - 62 - 16, size: 15, color: c.label, line: 20)
        body.frame.origin.y = (48 - TextLayout.firstBaseline(body)).rounded()
        let height = max(64, (body.frame.maxY + 13).rounded())
        let icon = P.group("App Icon", [tile, filled("chat-circle", center: CGPoint(x: 33, y: 19), size: 23, .white)]).moved(0, ((height - 38) / 2).rounded())
        return P.part([
            panel("Background", P.box(0, 0, w, height), radius: 24, c),
            icon,
            words("Ava Thompson", name: "Title", x: 62, baseline: 28, size: 15, weight: "Semibold", c.label),
            words(String(localized: "now"), name: "Time", x: w - 16, baseline: 28, size: 15, c.secondary, align: .right),
            body,
        ])
    }

    static let sheetHeader = Component(id: "ios.sheet-header", title: "Sheet Header", size: CGSize(width: 402, height: 76),
                                       fit: .across(margin: 0), minWidth: 280) { look in
        let c = Palette(dark: look.dark), w = look.width
        var sheet = P.rect("Background", P.box(0, 0, w, 76), c.cell, corners: [38, 38, 0, 0])
        sheet.cornerSmoothing = 0.6
        return P.part([
            sheet,
            P.pill("Grabber", P.box((w - 36) / 2, 5, 36, 5), c.grabber),
            glassCircle("Close", center: CGPoint(x: 38, y: 38), diameter: 44, symbol: "x", size: 15, stroke: 1.9, c),
            centered(String(localized: "New Event"), name: "Title", x: w / 2, y: 38, size: 17, weight: "Semibold", c.label),
            doneButton(at: CGPoint(x: w - 60, y: 16), c),
        ])
    }

    // MARK: - Keyboard

    static let keyboard = Component(id: "ios.keyboard", title: "Keyboard", size: CGSize(width: 402, height: 345), fit: .bottom, minWidth: 320) { look in
        let c = Palette(dark: look.dark), w = look.width, h: CGFloat = 345
        let back: RGBA = look.dark ? .hex("#171717F2") : .hex("#E3E5E9F2")
        let cap: RGBA = look.dark ? .hex("#414143") : .white
        var plate = P.rect("Background", P.box(0, 0, w, h), back, corners: [27, 27, 0, 0])
        plate.cornerSmoothing = 0.6
        plate = plate.frosted(20, tint: 1).outlined(look.dark ? .hex("#FFFFFF1F") : .hex("#0000000F"), width: 0.5)

        // Suggestions, in thirds.
        var suggestions: [Node] = []
        let words3 = [String(localized: "I"), String(localized: "The"), String(localized: "I’m")]
        for (i, word) in words3.enumerated() {
            suggestions.append(centered(word, name: "Suggestion \(i + 1)", x: w / 6 * CGFloat(i * 2 + 1), y: 25, size: 17,
                                        look.dark ? .hex("#FFFFFF99") : .hex("#000000A3")))
        }
        for i in 1...2 {
            suggestions.append(P.rect("Divider", P.box((w / 3 * CGFloat(i)).rounded() - 0.25, 16, 0.75, 18), look.dark ? .hex("#FFFFFF1A") : .hex("#0000000F")))
        }

        // Keys ten to a row, 7.75 apart; the rows 56 apart.
        let margin: CGFloat = 5, gap: CGFloat = 7.75
        let pitch = (w - 2 * margin + gap) / 10, key = pitch - gap
        let tops: [CGFloat] = [52, 108, 164, 220], height: CGFloat = 44
        func keyCap(_ name: String, _ x: CGFloat, _ row: Int, _ width: CGFloat, label: Node?) -> Node {
            let r = P.box(x, tops[row], width, height)
            var parts = [P.rect("Key", r, cap, radius: 8.5, smooth: true)]
            if let label { parts.append(label) }
            return P.group(name, parts)
        }
        func letter(_ s: String, _ x: CGFloat, _ row: Int) -> Node {
            keyCap(s, x, row, key, label: centered(s, name: "Label", x: x + key / 2, y: tops[row] + height / 2 - 1.5, size: 22.5, c.label))
        }
        var rows: [Node] = []
        let letters = ["QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"]
        var first: [Node] = [], second: [Node] = [], third: [Node] = []
        for (i, ch) in letters[0].enumerated() { first.append(letter(String(ch), margin + pitch * CGFloat(i), 0)) }
        for (i, ch) in letters[1].enumerated() { second.append(letter(String(ch), margin + pitch * (CGFloat(i) + 0.5), 1)) }
        let wide = pitch * 1.5 - 2 * gap
        third.append(keyCap("Shift", margin, 2, wide, label: filled("arrow-fat-up", center: CGPoint(x: margin + wide / 2, y: tops[2] + 21.5), size: 19, c.label)))
        for (i, ch) in letters[2].enumerated() { third.append(letter(String(ch), margin + pitch * (CGFloat(i) + 1.5), 2)) }
        third.append(keyCap("Delete", w - margin - wide, 2, wide,
                            label: symbol("delete", center: CGPoint(x: w - margin - wide / 2, y: tops[2] + 22), size: 21, stroke: 1.6, c.label)))
        let side = pitch * 2.5 - gap
        let fourth: [Node] = [
            keyCap("Numbers", margin, 3, side,
                   label: centered("123", name: "Label", x: margin + side / 2, y: tops[3] + 22, size: 17, c.label)),
            keyCap("Space", margin + pitch * 2.5, 3, pitch * 5 - gap, label: nil),
            keyCap("Return", w - margin - side, 3, side,
                   label: symbol("corner-down-left", center: CGPoint(x: w - margin - side / 2, y: tops[3] + 22), size: 19, stroke: 1.6, c.label)),
        ]
        rows.append(P.group("Row 1", first))
        rows.append(P.group("Row 2", second))
        rows.append(P.group("Row 3", third))
        rows.append(P.group("Row 4", fourth))
        return P.part([
            plate,
            P.group("Suggestions", suggestions),
            P.group("Keys", rows),
            symbol("face-slightly-smiling", center: CGPoint(x: 42, y: 305), size: 27, stroke: 1.6, look.dark ? .hex("#FFFFFFD9") : .hex("#2D2D2E")),
            symbol("mic", center: CGPoint(x: w - 43, y: 305), size: 27, stroke: 1.6, look.dark ? .hex("#FFFFFFD9") : .hex("#2D2D2E")),
            homeBar(w, bottom: h, c),
        ])
    }
}

// MARK: - Making the parts

nonisolated extension IOSKit {
    /// A part whose size is what it comes to, made once to see.
    fileprivate static func fixed(_ id: String, _ title: LocalizedStringResource, _ make: @escaping @Sendable (KitLook) -> Node) -> Component {
        Component(id: id, title: title, size: make(KitLook(width: 0)).frame.size, make: make)
    }

    /// Words on one line whose baseline is at `baseline`, as type is set on iOS.
    fileprivate static func words(_ s: String, name: String? = nil, x: CGFloat, baseline: CGFloat, size: CGFloat, weight: String = "Regular",
                                  _ color: RGBA, align: TextAlign = .left) -> Node {
        var n = P.text(s, name: name, x: x, y: 0, size: size, weight: weight, color: color, align: align)
        n.frame.origin.y = (baseline - TextLayout.firstBaseline(n)).rounded()
        return n
    }

    /// Words whose capitals stand in the middle of `y`, centred on `x` or starting there.
    fileprivate static func centered(_ s: String, name: String? = nil, x: CGFloat, y: CGFloat, size: CGFloat, weight: String = "Regular",
                                     _ color: RGBA, align: TextAlign = .center) -> Node {
        words(s, name: name ?? "Label", x: x, baseline: y + size * 0.705 / 2, size: size, weight: weight, color, align: align)
    }

    /// A Lucide symbol drawn as SF Symbols are: its drawing, not its box, `size` points at its
    /// longest and in the middle of `center`, its lines `stroke` points thick.
    fileprivate static func symbol(_ name: String, center c: CGPoint, size: CGFloat, stroke: CGFloat = 1.8, _ color: RGBA) -> Node {
        guard let icon = Icons.icon(name, in: .lucide) else { return P.icon(name, .lucide, center: c, size: size, color) }
        let raw = PathData.bounds(icon.paths[0])
        let unit = max(size - stroke, 1) / max(raw.width, raw.height, 0.01)
        let box = CGRect(x: c.x - raw.midX * unit, y: c.y - raw.midY * unit, width: 24 * unit, height: 24 * unit)
        return P.icon(name, .lucide, box, color, weight: stroke / unit)
    }

    /// A filled Phosphor symbol, its drawing `size` points at its longest, in the middle of `center`.
    fileprivate static func filled(_ name: String, center c: CGPoint, size: CGFloat, _ color: RGBA) -> Node {
        let set = Icons.set(.phosphor)
        guard let icon = set.icon(name), icon.paths.count > 4, !icon.paths[4].isEmpty else {
            return P.icon(name, .phosphor, center: c, size: size, color, style: 4)
        }
        let raw = PathData.bounds(icon.paths[4])
        let k = size / max(raw.width, raw.height, 0.01)
        let box = CGRect(x: c.x - (raw.midX - set.box.minX) * k, y: c.y - (raw.midY - set.box.minY) * k,
                         width: set.box.width * k, height: set.box.height * k)
        return P.icon(name, .phosphor, box, color, style: 4)
    }

    /// Liquid Glass: what lies behind blurred under a pale or dark tint, the edge catching the light
    /// inside, and a hairline and a soft shadow outside.
    fileprivate static func glass(_ name: String, _ r: CGRect, radius: CGFloat? = nil, _ c: Palette) -> Node {
        var n = P.rect(name, r, c.glass, radius: radius ?? min(r.width, r.height) / 2, smooth: radius != nil)
        n.blur = Blur(on: true, radius: 14, background: true, brightness: c.dark ? 0 : 0.1, fillOpacity: 1)
        n.borders = [P.border(c.glassRim, width: 1, position: .inside), P.border(c.glassEdge, width: 0.5, position: .outside)]
        n.shadows = [P.shadow(y: 6, blur: 20, c.glassShadow), Shadow(on: true, color: c.glassShade, x: 0, y: 0, blur: 10, inset: true)]
        return n
    }

    /// The thicker glass an alert, a menu or a notification is drawn on.
    fileprivate static func panel(_ name: String, _ r: CGRect, radius: CGFloat, _ c: Palette) -> Node {
        var n = P.rect(name, r, c.panel, radius: radius, smooth: true)
        n.blur = Blur(on: true, radius: 30, background: true, brightness: 0, fillOpacity: 1)
        n.borders = [P.border(c.glassRim, width: 1, position: .inside), P.border(c.glassEdge, width: 0.5, position: .outside)]
        n.shadows = [P.shadow(y: 16, blur: 48, .hex(c.dark ? "#00000080" : "#0000002E"))]
        return n
    }

    /// A round glass button with a symbol in it.
    fileprivate static func glassCircle(_ name: String, center: CGPoint, diameter: CGFloat, symbol icon: String, size: CGFloat,
                                        stroke: CGFloat = 1.8, _ c: Palette, nudge: CGFloat = 0) -> Node {
        let r = P.box(center.x - diameter / 2, center.y - diameter / 2, diameter, diameter)
        return P.group(name, [glass("Glass", r, c), symbol(icon, center: CGPoint(x: center.x + nudge, y: center.y), size: size, stroke: stroke, c.label)])
    }

    /// Several symbols sharing one glass capsule, as a navigation bar groups its buttons.
    fileprivate static func itemGroup(_ icons: [String], right: CGFloat, _ c: Palette) -> Node {
        let slot: CGFloat = 48, pad: CGFloat = 5
        let width = slot * CGFloat(icons.count) + pad * 2
        let r = P.box(right - width, 0, width, 44)
        var items: [Node] = [glass("Glass", r, c)]
        for (i, icon) in icons.enumerated() {
            items.append(symbol(icon, center: CGPoint(x: r.minX + pad + slot * (CGFloat(i) + 0.5), y: 22), size: icon == "ellipsis" ? 20 : 19, c.label))
        }
        return P.group("Group", items)
    }

    /// A glass capsule with a word in it, its right edge at `right`.
    fileprivate static func textButton(_ name: String, _ label: String, right: CGFloat, y: CGFloat, height: CGFloat, _ c: Palette) -> Node {
        let width = max(height, (P.width(of: label, size: 17, weight: "Medium") + 30).rounded())
        return P.group(name, [glass("Glass", P.box(right - width, y, width, height), c),
                               centered(label, x: right - width / 2, y: y + height / 2, size: 17, weight: "Medium", c.label)])
    }

    /// The blue round button with a checkmark that confirms a sheet.
    fileprivate static func doneButton(at p: CGPoint, _ c: Palette) -> Node {
        let r = P.box(p.x, p.y, 44, 44)
        let face = P.pill("Glass", r, c.blue).outlined(.hex("#FFFFFF33"), width: 1)
            .casting(P.shadow(y: 6, blur: 20, c.glassShadow))
        return P.group("Done", [face, symbol("check", center: CGPoint(x: r.midX, y: r.midY + 0.5), size: 18, stroke: 2.2, .white)])
    }

    /// The home indicator, its bottom 8 points above `bottom`.
    fileprivate static func homeBar(_ w: CGFloat, bottom: CGFloat, _ c: Palette) -> Node {
        P.pill("Home Indicator", P.box((w - 140) / 2, bottom - 13, 140, 5), c.label)
    }

    /// A switch, green when on, its white knob a capsule.
    fileprivate static func switchControl(on: Bool, _ c: Palette) -> Node {
        P.part([
            P.pill("Track", P.box(0, 0, 64, 28), on ? c.green : c.fill),
            P.pill("Knob", P.box(on ? 24 : 2, 2, 38, 24), .white)
                .casting(P.shadow(y: 2, blur: 6, .hex("#0000001F")), P.shadow(y: 0, blur: 1, .hex("#0000000F"))),
        ])
    }

    /// The Wi-Fi sign: three bands fanning up from a point, filled.
    fileprivate static func wifi(right: CGFloat, bottom: CGFloat, _ color: RGBA) -> Node {
        let cx = right - 8.75, cy = bottom - 0.2
        let spread = 46.0 * Double.pi / 180
        func at(_ r: CGFloat, _ side: Double) -> String {
            let a = -Double.pi / 2 + side * spread
            return String(format: "%.3f %.3f", Double(cx) + Double(r) * cos(a), Double(cy) + Double(r) * sin(a))
        }
        func band(_ inner: CGFloat, _ outer: CGFloat) -> String {
            "M\(at(outer, -1))A\(outer) \(outer) 0 0 1 \(at(outer, 1))L\(at(inner, 1))A\(inner) \(inner) 0 0 0 \(at(inner, -1))Z"
        }
        let data = band(9.4, 12.2) + band(4.9, 7.7) + "M\(cx) \(cy)L\(at(3.3, -1))A3.3 3.3 0 0 1 \(at(3.3, 1))Z"
        let box = PathData.bounds(data)
        return P.shape("Wi-Fi", data, box: box, in: box, color)
    }

    /// Each tab's symbol, its layer's name and its label.
    fileprivate static let standardTabs: [(String, String, String)] = [
        ("house", "Home", String(localized: "Home")), ("squares-four", "Browse", String(localized: "Browse")),
        ("books", "Library", String(localized: "Library")), ("user-circle", "Profile", String(localized: "Profile")),
    ]

    /// The tabs of a tab bar, the first selected, on a lighter glass of its own.
    fileprivate static func tabs(_ list: [(String, String, String)], in bar: CGRect, badge: Int?, _ c: Palette) -> [Node] {
        let step = (bar.width - 8) / CGFloat(list.count)
        var items: [Node] = []
        for (i, (icon, name, label)) in list.enumerated() {
            let x = bar.minX + 4 + step * CGFloat(i)
            let on = i == 0
            let tint = on ? c.blue : c.label
            var tab: [Node] = []
            if on {
                tab.append(P.pill("Selection", P.box(x, bar.minY + 4, step, bar.height - 8), c.platter)
                    .outlined(.hex(c.dark ? "#FFFFFF14" : "#0000000A"), width: 0.5))
            }
            let mid = CGPoint(x: (x + step / 2).rounded(), y: bar.minY + 24.5)
            tab.append(filled(icon, center: mid, size: 24, tint))
            tab.append(words(label, name: "Label", x: mid.x, baseline: bar.minY + 49.5, size: 10, weight: "Semibold", tint, align: .center))
            if badge == i {
                tab.append(P.group("Badge", [
                    P.circle("Background", center: CGPoint(x: mid.x + 13, y: mid.y - 8), radius: 9, c.red),
                    centered("2", name: "Count", x: mid.x + 13, y: mid.y - 8, size: 13, weight: "Medium", .white),
                ]))
            }
            items.append(P.group(name, tab))
        }
        return [P.group("Tabs", items)]
    }

    fileprivate enum Glyph { case line(String), filled(String) }
    fileprivate enum Trailing { case chevron, value(String), plain(String), toggle(Bool) }

    /// A row of an inset grouped list, 52 tall: maybe a coloured tile with a white symbol, its
    /// label, and what it shows at its end; a separator under it from the label on, unless last.
    fileprivate static func row(_ index: Int, _ name: String, icon: Glyph?, tint: RGBA?, _ label: String, trailing: Trailing, _ w: CGFloat, _ c: Palette,
                                last: Bool = false) -> Node {
        let top = CGFloat(index) * 52, mid = top + 26
        var parts: [Node] = []
        var textX: CGFloat = 16
        if let icon, let tint {
            let tile = P.rect("Tile", P.box(16, mid - 15, 30, 30), tint, radius: 7.5, smooth: true)
            let glyph: Node
            switch icon {
            case .line(let name): glyph = symbol(name, center: CGPoint(x: 31, y: mid), size: 18, stroke: 2.1, .white)
            case .filled(let name): glyph = filled(name, center: CGPoint(x: 31, y: mid), size: 19, .white)
            }
            parts.append(P.group("Icon", [tile, glyph]))
            textX = 60
        }
        parts.append(centered(label, name: "Label", x: textX, y: mid, size: 17, c.label, align: .left))
        let chevronX = w - 16 - 3.5
        switch trailing {
        case .chevron:
            parts.append(symbol("chevron-right", center: CGPoint(x: chevronX, y: mid), size: 12, stroke: 2.1, c.tertiary))
        case .value(let value):
            parts.append(centered(value, name: "Value", x: chevronX - 3.5 - 14, y: mid, size: 17, c.secondary, align: .right))
            parts.append(symbol("chevron-right", center: CGPoint(x: chevronX, y: mid), size: 12, stroke: 2.1, c.tertiary))
        case .plain(let value):
            parts.append(centered(value, name: "Value", x: w - 16, y: mid, size: 17, c.secondary, align: .right))
        case .toggle(let on):
            parts.append(switchControl(on: on, c).named("Toggle").moved(w - 16 - 64, mid - 14))
        }
        if !last { parts.append(P.rule(x: textX, y: top + 51.5, width: w - textX - 16, c.separator)) }
        return P.group(name, parts)
    }
}
