import Foundation
import CoreGraphics

private typealias P = Parts

/// macOS as it looks now: Liquid Glass toolbars, sidebars, menus and the Dock floating over the
/// content, controls 24 points tall and rounder than they were, SF Pro at 13 points, the accent blue.
nonisolated enum MacKit {
    static let kit = Kit(id: "macos", title: "macOS", paper: .white, darkPaper: .hex("#1E1E1E"), sections: [
        KitSection(title: "Windows", components: [window, trafficLights, toolbar, sidebar, menuBar, dock]),
        KitSection(title: "Buttons", components: [defaultButton, pushButton, largeButton, popUpButton, pullDownButton,
                                                  helpButton, toolbarButton, toolbarGroup, disclosure]),
        KitSection(title: "Controls", components: [checkboxOn, checkboxOff, radioOn, radioOff, switchOn, switchOff,
                                                   segmentedControl, slider, tickSlider, stepper, colorWell, progressBar, spinner]),
        KitSection(title: "Text Fields", components: [textField, searchField, tokenField]),
        KitSection(title: "Containers", components: [alert, menu, popover, tooltip, table, tabView, notification]),
    ])

    /// The system's colours, light or dark, as they are drawn on a window.
    struct Palette {
        let dark: Bool
        var label: RGBA { dark ? .hex("#FFFFFFD9") : .hex("#000000D9") }
        var secondary: RGBA { dark ? .hex("#FFFFFF8C") : .hex("#00000080") }
        var tertiary: RGBA { dark ? .hex("#FFFFFF40") : .hex("#00000042") }
        var accent: RGBA { .hex("#007AFF") }
        /// A selected row: the accent, a little deeper.
        var selection: RGBA { dark ? .hex("#0059D1") : .hex("#0064E1") }
        var window: RGBA { dark ? .hex("#1E1E1E") : .white }
        /// Push buttons, pop-ups, a segmented control's track.
        var control: RGBA { dark ? .hex("#FFFFFF17") : .hex("#00000014") }
        /// What a checkbox, a radio button, a slider or a colour well is set in.
        var well: RGBA { dark ? .hex("#FFFFFF1C") : .hex("#0000001A") }
        var switchOff: RGBA { dark ? .hex("#FFFFFF1E") : .hex("#0000001F") }
        var progressTrack: RGBA { dark ? .hex("#FFFFFF14") : .hex("#0000000F") }
        var field: RGBA { dark ? .hex("#1E1E1E") : .white }
        var fieldBorder: RGBA { dark ? .hex("#FFFFFF24") : .hex("#00000026") }
        var separator: RGBA { dark ? .hex("#FFFFFF1F") : .hex("#0000001A") }
        var stripe: RGBA { dark ? .hex("#FFFFFF0C") : .hex("#F4F5F5") }
        var box: RGBA { dark ? .hex("#FFFFFF08") : .hex("#00000008") }
        var token: RGBA { dark ? .hex("#0F4064") : .hex("#AAD8FF") }
        var tokenText: RGBA { dark ? .hex("#FFFFFFE6") : .hex("#1E272F") }
        var knobShadow: RGBA { dark ? .hex("#00000066") : .hex("#00000033") }
        /// Liquid Glass of the toolbar's buttons.
        var glass: RGBA { dark ? .hex("#3E3E40E6") : .hex("#FFFFFFE6") }
        var glassRim: RGBA { dark ? .hex("#FFFFFF2E") : .hex("#00000021") }
        var glassShadow: RGBA { dark ? .hex("#00000052") : .hex("#00000014") }
        /// What lies selected in a glass group of buttons.
        var glassSelected: RGBA { dark ? .hex("#FFFFFF1A") : .hex("#0000001A") }
        /// Liquid Glass of what floats over everything: menus, popovers, alerts, notifications.
        var panel: RGBA { dark ? .hex("#2A2A2CE0") : .hex("#F8F8F8E0") }
        var panelRim: RGBA { dark ? .hex("#FFFFFF2B") : .hex("#0000001A") }
        var panelShadow: RGBA { dark ? .hex("#00000080") : .hex("#00000033") }
        /// The glass a window's sidebar floats in.
        var sidebar: RGBA { dark ? .hex("#2B2B2DF0") : .hex("#EDEDF0F0") }
        var sidebarRim: RGBA { dark ? .hex("#FFFFFF1F") : .hex("#00000012") }
    }

    // MARK: - Windows

    static let window = Component(id: "macos.window", title: "Window", size: CGSize(width: 900, height: 560)) { look in
        let c = Palette(dark: look.dark)
        let w: CGFloat = 900, h: CGFloat = 560
        let side = CGRect(x: 8, y: 8, width: 220, height: h - 16)
        // The content lies under the sidebar and the toolbar, which float over it.
        let background = P.rect("Background", P.box(0, 0, w, h), c.window, radius: 22, smooth: true)
            .outlined(look.dark ? .hex("#FFFFFF26") : .hex("#00000026"), width: 0.5)
            .casting(P.shadow(y: 24, blur: 64, look.dark ? .hex("#00000099") : .hex("#00000040")),
                     P.shadow(y: 0, blur: 1, look.dark ? .hex("#000000CC") : .hex("#0000001F")))
        let navX = side.maxX + 14
        let search = P.box(w - 8 - 200, 8, 200, 36)
        let share = P.box(search.minX - 10 - 36, 8, 36, 36)
        let views = P.box(share.minX - 10 - 76, 8, 76, 36)
        let toolbar = P.group("Toolbar", [
            navigation(x: navX, c),
            P.text(String(localized: "Documents"), name: "Title", in: P.box(navX + 80 + 14, 8, 200, 36), size: 15, weight: "Bold", color: c.label),
            viewGroup(views, c, items: ["layout-grid", "list"]),
            glassButton("Share", "share", share, c),
            searchCapsule(search, c),
        ])
        return P.part([
            background,
            P.group("Content", files(x: side.maxX + 26, y: 72, c)),
            sidebarPanel(side, c),
            toolbar,
        ])
    }

    static let trafficLights = Component(id: "macos.traffic-lights", title: "Traffic Lights", size: CGSize(width: 60, height: 14)) { _ in
        let lights = lights(x: 0, y: 0)
        return P.part(lights.children)
    }

    static let toolbar = Component(id: "macos.toolbar", title: "Toolbar", size: CGSize(width: 900, height: 52), fit: .top, minWidth: 620) { look in
        let c = Palette(dark: look.dark), w = look.width
        let search = P.box(w - 8 - 180, 8, 180, 36)
        let share = P.box(search.minX - 10 - 36, 8, 36, 36)
        let views = P.box(share.minX - 10 - 76, 8, 76, 36)
        return P.part([
            P.frame(w, 52),
            lights(x: 19, y: 19),
            navigation(x: 96, c),
            P.text(String(localized: "Documents"), name: "Title", in: P.box(96 + 80 + 14, 8, 200, 36), size: 15, weight: "Bold", color: c.label),
            viewGroup(views, c, items: ["layout-grid", "list"]),
            glassButton("Share", "share", share, c),
            searchCapsule(search, c),
        ])
    }

    static let sidebar = Component(id: "macos.sidebar", title: "Sidebar", size: CGSize(width: 236, height: 560)) { look in
        let c = Palette(dark: look.dark)
        return P.part([
            P.frame(236, 560),
            sidebarPanel(P.box(8, 8, 220, 544), c),
        ])
    }

    static let menuBar = Component(id: "macos.menu-bar", title: "Menu Bar", size: CGSize(width: 1440, height: 24), fit: .top, minWidth: 760) { look in
        let c = Palette(dark: look.dark), w = look.width
        let ink: RGBA = look.dark ? .white : .hex("#000000E6")
        var menus: [Node] = [P.icon("command", .lucide, center: CGPoint(x: 22, y: 12), size: 15, ink, weight: 2.2).named("System Menu")]
        var x: CGFloat = 46
        let titles = ["Studio", String(localized: "File"), String(localized: "Edit"), String(localized: "View"),
                      String(localized: "Window"), String(localized: "Help")]
        for (i, title) in titles.enumerated() {
            let t = P.text(title, in: P.box(x, 0, 100, 24), size: 13, weight: i == 0 ? "Bold" : "Medium", color: ink)
            menus.append(t)
            x += t.frame.width + 21
        }
        // The status items from the right: the date and time, Control Centre, Spotlight, Wi-Fi, the battery.
        let time = P.text(String(localized: "Tue 4 Nov") + "  9:41", name: "Clock", in: P.box(0, 0, w - 14, 24), size: 13, weight: "Medium", color: ink, align: .right)
        var status: [Node] = [time]
        var cx = time.frame.minX - 22
        status.append(controlCentre(CGPoint(x: cx, y: 12), ink: ink))
        cx -= 30
        status.append(P.icon("search", .lucide, center: CGPoint(x: cx, y: 12), size: 15, ink, weight: 2.4).named("Spotlight"))
        cx -= 30
        status.append(P.icon("wifi", .lucide, center: CGPoint(x: cx, y: 12), size: 16, ink, weight: 2.4).named("Wi-Fi"))
        cx -= 34
        status.append(battery(x: cx - 13, y: 6, c, ink: ink))
        return P.part([
            P.frame(w, 24),
            P.group("Menus", menus),
            P.group("Status Items", status),
        ])
    }

    /// The Dock's apps, each a tile of colour and a glyph, none of them a real app's icon.
    private static let dockApps: [(name: String, glyph: String, top: String, bottom: String, ink: String?, running: Bool)] = [
        ("Files", "folder", "#5AC2FF", "#1A84EF", nil, true),
        ("Browser", "globe", "#48DCCB", "#0E9F9A", nil, true),
        ("Messages", "message-circle", "#6FE383", "#26B94B", nil, true),
        ("Mail", "mail", "#7D8CFF", "#4652E3", nil, false),
        ("Calendar", "calendar", "#FFFFFF", "#ECECEF", "#FF3B30", false),
        ("Photos", "image", "#FFB54D", "#FF5A7D", nil, true),
        ("Music", "audio-lines", "#FF7B8C", "#EE2F4E", nil, false),
        ("Notes", "notebook-pen", "#FFE57F", "#FFC423", "#6B4F00", false),
        ("Settings", "settings", "#CDCDD3", "#8C8C94", nil, false),
    ]

    private static let dockTile: CGFloat = 52
    private static let dockWidth: CGFloat = {
        let n = CGFloat(dockApps.count)
        let apps: CGFloat = n * dockTile + (n - 1) * 6
        let stacks: CGFloat = dockTile * 2 + 6
        return 8 + apps + 19 + stacks + 8
    }()

    static let dock = Component(id: "macos.dock", title: "Dock", size: CGSize(width: dockWidth, height: 70)) { look in
        let c = Palette(dark: look.dark)
        let t = dockTile
        var apps: [Node] = []
        var dots: [Node] = []
        var x: CGFloat = 8
        for app in dockApps {
            apps.append(appTile(app.name, P.box(x, 8, t, t), top: app.top, bottom: app.bottom, glyph: app.glyph,
                                ink: app.ink.map { RGBA.hex($0) } ?? .white))
            if app.running {
                dots.append(P.oval("Running Light", P.box(x + t / 2 - 2, 8 + t + 3, 4, 4), c.label.with(alpha: 0.7)))
            }
            x += t + 6
        }
        x += 3
        let divider = P.rect("Divider", P.box(x, 14, 1, t - 12), look.dark ? .hex("#FFFFFF33") : .hex("#0000002E"))
        x += 10
        var stacks: [Node] = [appTile("Downloads", P.box(x, 8, t, t), top: "#9AD7FF", bottom: "#3FA0F4", glyph: "folder-down", ink: .white)]
        x += t + 6
        var bin = P.rect("Tile", P.box(x, 8, t, t), .white, radius: t * 0.225, smooth: true)
        bin.fill.gradient = vertical(look.dark ? "#FFFFFF40" : "#FFFFFFE6", look.dark ? "#FFFFFF1A" : "#E4E4E9E6")
        stacks.append(P.group("Bin", [
            bin.outlined(look.dark ? .hex("#FFFFFF33") : .hex("#0000001A"), width: 0.5),
            P.icon("trash", .lucide, center: CGPoint(x: x + t / 2, y: 8 + t / 2), size: 28, look.dark ? .hex("#FFFFFFCC") : .hex("#6E6E73"), weight: 1.7),
        ]))
        return P.part([
            P.rect("Glass", P.box(0, 0, dockWidth, 70), look.dark ? .hex("#3A3A3CB8") : .hex("#F6F6F8B8"), radius: 22, smooth: true)
                .frosted(24, tint: 1).outlined(look.dark ? .hex("#FFFFFF2E") : .hex("#FFFFFFCC"), width: 0.5)
                .casting(P.shadow(y: 10, blur: 30, look.dark ? .hex("#00000080") : .hex("#00000029")),
                         P.shadow(y: 0, blur: 1, look.dark ? .hex("#000000B3") : .hex("#00000026"))),
            P.group("Apps", apps),
            divider,
            P.group("Stacks", stacks),
            P.group("Running Lights", dots),
        ])
    }

    // MARK: - Buttons

    static let defaultButton = Component(id: "macos.default-button", title: "Default Button", size: CGSize(width: 80, height: 24)) { look in
        let c = Palette(dark: look.dark)
        return pushButton(String(localized: "Save"), P.box(0, 0, 80, 24), c, accent: true)
    }

    static let pushButton = Component(id: "macos.push-button", title: "Push Button", size: CGSize(width: 80, height: 24)) { look in
        let c = Palette(dark: look.dark)
        return pushButton(String(localized: "Cancel"), P.box(0, 0, 80, 24), c, accent: false)
    }

    static let largeButton = Component(id: "macos.large-button", title: "Large Button", size: CGSize(width: 140, height: 28)) { look in
        let c = Palette(dark: look.dark)
        let r = P.box(0, 0, 140, 28)
        return P.part([
            P.pill("Background", r, c.accent),
            P.text(String(localized: "Continue"), name: "Label", in: r, size: 13, weight: "Medium", color: .white, align: .center),
        ])
    }

    static let popUpButton = Component(id: "macos.pop-up-button", title: "Pop-up Button", size: CGSize(width: 104, height: 24)) { look in
        let c = Palette(dark: look.dark)
        let r = P.box(0, 0, 104, 24)
        return P.part([
            P.rect("Background", r, c.control, radius: 6),
            P.text(String(localized: "Automatic"), name: "Label", in: P.box(11, 0, 70, 24), size: 13, color: c.label),
            P.icon("chevrons-up-down", .lucide, center: CGPoint(x: 104 - 13, y: 12), size: 13, c.label, weight: 2.6).named("Arrows"),
        ])
    }

    static let pullDownButton = Component(id: "macos.pull-down-button", title: "Pull-down Button", size: CGSize(width: 96, height: 24)) { look in
        let c = Palette(dark: look.dark)
        let r = P.box(0, 0, 96, 24)
        return P.part([
            P.rect("Background", r, c.control, radius: 6),
            P.text(String(localized: "Actions"), name: "Label", in: P.box(11, 0, 70, 24), size: 13, color: c.label),
            P.icon("chevron-down", .lucide, center: CGPoint(x: 96 - 14, y: 12.5), size: 12, c.label, weight: 3).named("Arrow"),
        ])
    }

    static let helpButton = Component(id: "macos.help-button", title: "Help Button", size: CGSize(width: 24, height: 24)) { look in
        let c = Palette(dark: look.dark)
        let r = P.box(0, 0, 24, 24)
        return P.part([
            P.oval("Background", r, c.control),
            P.text("?", name: "Question Mark", in: r.offsetBy(dx: 0, dy: -0.5), size: 15, weight: "Medium", color: c.label, align: .center),
        ])
    }

    static let toolbarButton = Component(id: "macos.toolbar-button", title: "Toolbar Button", size: CGSize(width: 36, height: 36)) { look in
        let c = Palette(dark: look.dark)
        return P.part(glassButton("Share", "share", P.box(0, 0, 36, 36), c).children)
    }

    static let toolbarGroup = Component(id: "macos.toolbar-group", title: "Toolbar Group", size: CGSize(width: 112, height: 36)) { look in
        let c = Palette(dark: look.dark)
        return P.part(viewGroup(P.box(0, 0, 112, 36), c, items: ["layout-grid", "list", "columns-3"]).children)
    }

    static let disclosure: Component = {
        let label = String(localized: "Show Details")
        let width = 18 + P.width(of: label, size: 13)
        return Component(id: "macos.disclosure", title: "Disclosure Triangle", size: CGSize(width: width, height: 16)) { look in
            let c = Palette(dark: look.dark)
            return P.part([
                P.icon("chevron-right", .lucide, center: CGPoint(x: 6.5, y: 8), size: 12, c.secondary, weight: 3).named("Triangle"),
                P.text(label, name: "Label", in: P.box(18, 0, 200, 16), size: 13, color: c.label),
            ])
        }
    }()

    // MARK: - Controls

    static let checkboxOn = labelled("macos.checkbox-on", "Checkbox On", String(localized: "Show in menu bar")) { c in
        P.group("Checkbox", [
            P.rect("Box", P.box(0, 0, 16, 16), c.accent, radius: 4.5),
            P.icon("check", .lucide, center: CGPoint(x: 8, y: 8.2), size: 12, .white, weight: 4).named("Check"),
        ])
    }

    static let checkboxOff = labelled("macos.checkbox-off", "Checkbox Off", String(localized: "Open at login")) { c in
        P.rect("Box", P.box(0, 0, 16, 16), c.well, radius: 4.5)
    }

    static let radioOn = labelled("macos.radio-on", "Radio Button On", String(localized: "Automatic")) { c in
        P.group("Radio Button", [
            P.oval("Circle", P.box(0, 0, 16, 16), c.accent),
            P.oval("Dot", P.box(5.5, 5.5, 5, 5), .white),
        ])
    }

    static let radioOff = labelled("macos.radio-off", "Radio Button Off", String(localized: "Manual")) { c in
        P.oval("Circle", P.box(0, 0, 16, 16), c.well)
    }

    static let switchOn = Component(id: "macos.switch-on", title: "Switch On", size: CGSize(width: 54, height: 24)) { look in
        let c = Palette(dark: look.dark)
        return P.part([
            P.pill("Track", P.box(0, 0, 54, 24), c.accent),
            knob(P.box(20, 2, 32, 20), c),
        ])
    }

    static let switchOff = Component(id: "macos.switch-off", title: "Switch Off", size: CGSize(width: 54, height: 24)) { look in
        let c = Palette(dark: look.dark)
        return P.part([
            P.pill("Track", P.box(0, 0, 54, 24), c.switchOff),
            knob(P.box(2, 2, 32, 20), c),
        ])
    }

    /// Day, Week, Month and Year, each as wide as its word and some room.
    private static func segments() -> (labels: [String], widths: [CGFloat], total: CGFloat) {
        let labels = [String(localized: "Day"), String(localized: "Week"), String(localized: "Month"), String(localized: "Year")]
        let widths = labels.map { (P.width(of: $0, size: 13) + 26).rounded() }
        return (labels, widths, widths.reduce(0, +) + 4)
    }

    static let segmentedControl = Component(id: "macos.segmented-control", title: "Segmented Control",
                                            size: CGSize(width: segments().total, height: 24)) { look in
        let c = Palette(dark: look.dark)
        let (labels, widths, total) = segments()
        var layers: [Node] = [P.rect("Track", P.box(0, 0, total, 24), c.control, radius: 6)]
        var x: CGFloat = 2
        let selected = 1
        for (i, label) in labels.enumerated() {
            let r = P.box(x, 0, widths[i], 24)
            var segment: [Node] = []
            if i == selected {
                segment.append(P.rect("Selection", P.box(x - 2, 0, widths[i] + 4, 24), c.accent, radius: 6))
            }
            segment.append(P.text(label, name: "Label", in: r, size: 13, weight: i == selected ? "Medium" : "Regular",
                                  color: i == selected ? .white : c.label, align: .center))
            layers.append(P.group(label, segment))
            // A divider only between two segments neither of which is selected.
            if i < labels.count - 1 && i != selected && i + 1 != selected {
                layers.append(P.rect("Divider", P.box(x + widths[i] - 0.5, 5, 1, 14), c.label.with(alpha: look.dark ? 0.25 : 0.2)))
            }
            x += widths[i]
        }
        return P.part(layers)
    }

    static let slider = Component(id: "macos.slider", title: "Slider", size: CGSize(width: 240, height: 16)) { look in
        let c = Palette(dark: look.dark)
        let at: CGFloat = 0.6 * 220 + 10
        return P.part([
            P.frame(240, 16),
            P.pill("Track", P.box(0, 5, 240, 6), c.well),
            P.pill("Fill", P.box(0, 5, at, 6), c.accent),
            knob(P.box(at - 10, 0, 20, 16), c),
        ])
    }

    static let tickSlider = Component(id: "macos.slider-ticks", title: "Slider with Ticks", size: CGSize(width: 240, height: 22)) { look in
        let c = Palette(dark: look.dark)
        // Eleven stops; the knob rests on the fifth, and the tick under it is hidden by nothing.
        let step: CGFloat = 220 / 10
        let at: CGFloat = 10 + step * 4
        var ticks: [Node] = []
        for i in 0...10 {
            ticks.append(P.oval("Tick", P.box(10 + step * CGFloat(i) - 1, 20, 2, 2), c.tertiary))
        }
        return P.part([
            P.frame(240, 22),
            P.pill("Track", P.box(0, 5, 240, 6), c.well),
            P.pill("Fill", P.box(0, 5, at, 6), c.accent),
            P.group("Ticks", ticks),
            knob(P.box(at - 10, 0, 20, 16), c),
        ])
    }

    static let stepper = Component(id: "macos.stepper", title: "Stepper", size: CGSize(width: 72, height: 26)) { look in
        let c = Palette(dark: look.dark)
        let field = P.box(0, 0, 48, 26)
        let arrows = P.box(52, 1, 20, 24)
        return P.part([
            P.group("Field", [
                P.rect("Background", field, c.field, radius: 7).outlined(c.fieldBorder, width: 1),
                P.text("12", name: "Value", in: field.insetBy(dx: 9, dy: 0), size: 13, color: c.label, align: .right),
            ]),
            P.group("Arrows", [
                P.rect("Background", arrows, c.control, radius: 6),
                P.icon("chevron-up", .lucide, center: CGPoint(x: arrows.midX, y: arrows.minY + 6.5), size: 11, c.label, weight: 3).named("Up"),
                P.rule("Divider", x: arrows.minX + 5, y: arrows.midY - 0.25, width: 10, c.separator),
                P.icon("chevron-down", .lucide, center: CGPoint(x: arrows.midX, y: arrows.maxY - 6.5), size: 11, c.label, weight: 3).named("Down"),
            ]),
        ])
    }

    static let colorWell = Component(id: "macos.color-well", title: "Color Well", size: CGSize(width: 48, height: 24)) { look in
        let c = Palette(dark: look.dark)
        return P.part([
            P.pill("Well", P.box(0, 0, 48, 24), c.well),
            P.pill("Colour", P.box(3, 3, 42, 18), .hex("#FF8D28")).outlined(.hex("#00000026"), width: 1),
        ])
    }

    static let progressBar = Component(id: "macos.progress-bar", title: "Progress Bar", size: CGSize(width: 200, height: 8)) { look in
        let c = Palette(dark: look.dark)
        return P.part([
            P.pill("Track", P.box(0, 0, 200, 8), c.progressTrack),
            P.pill("Progress", P.box(0, 0, 120, 8), c.accent),
        ])
    }

    static let spinner = Component(id: "macos.spinner", title: "Spinner", size: CGSize(width: 32, height: 32)) { look in
        // Eight spokes, the darkest on top, fading the way it turns from.
        let alphas: [Double] = [0.58, 0.47, 0.42, 0.36, 0.29, 0.21, 0.14, 0.08]
        var spokes: [Node] = []
        for (i, a) in alphas.enumerated() {
            let angle = -Double.pi / 2 - Double(i) * Double.pi / 4
            let dx = CGFloat(cos(angle)), dy = CGFloat(sin(angle))
            spokes.append(P.line("Spoke", from: CGPoint(x: 16 + dx * 8, y: 16 + dy * 8), to: CGPoint(x: 16 + dx * 13.6, y: 16 + dy * 13.6),
                                 (look.dark ? RGBA.white : RGBA.black).with(alpha: look.dark ? a + 0.12 : a), width: 3.2))
        }
        return P.part([P.frame(32, 32), P.group("Spokes", spokes)])
    }

    // MARK: - Text fields

    static let textField = Component(id: "macos.text-field", title: "Text Field", size: CGSize(width: 220, height: 26)) { look in
        let c = Palette(dark: look.dark)
        let r = P.box(0, 0, 220, 26)
        return P.part([
            P.rect("Background", r, c.field, radius: 7).outlined(c.fieldBorder, width: 1),
            P.text(String(localized: "Full Name"), name: "Placeholder", in: r.insetBy(dx: 8, dy: 0), size: 13, color: c.secondary),
        ])
    }

    static let searchField = Component(id: "macos.search-field", title: "Search Field", size: CGSize(width: 220, height: 26)) { look in
        let c = Palette(dark: look.dark)
        let r = P.box(0, 0, 220, 26)
        return P.part([
            P.pill("Background", r, c.field).outlined(c.fieldBorder, width: 1),
            P.icon("search", .lucide, center: CGPoint(x: 15, y: 13), size: 14, c.secondary, weight: 2.4).named("Magnifier"),
            P.text(String(localized: "Search"), name: "Placeholder", in: P.box(26, 0, 180, 26), size: 13, color: c.secondary),
        ])
    }

    static let tokenField = Component(id: "macos.token-field", title: "Token Field", size: CGSize(width: 260, height: 26)) { look in
        let c = Palette(dark: look.dark)
        let r = P.box(0, 0, 260, 26)
        var layers: [Node] = [P.rect("Background", r, c.field, radius: 7).outlined(c.fieldBorder, width: 1)]
        var x: CGFloat = 6
        for word in [String(localized: "Design"), String(localized: "Draft"), String(localized: "Urgent")] {
            let tw = P.width(of: word, size: 13) + 16
            layers.append(P.group(word, [
                P.rect("Token", P.box(x, 5, tw, 16), c.token, radius: 4),
                P.text(word, name: "Label", in: P.box(x, 5, tw, 16), size: 13, color: c.tokenText, align: .center),
            ]))
            x += tw + 5
        }
        return P.part(layers)
    }

    // MARK: - Containers

    static let alert: Component = {
        let message = String(localized: "This item will be deleted immediately. You can’t undo this action.")
        // As tall as its message: the buttons lie 16 points under it.
        let lines = P.paragraph(message, x: 0, y: 0, width: 220, size: 13, color: .black).frame.height.rounded(.up)
        let h = 126 + lines + 16 + 28 + 16
        return Component(id: "macos.alert", title: "Alert", size: CGSize(width: 260, height: h)) { look in
            let c = Palette(dark: look.dark)
            var icon = P.rect("Icon", P.box(20, 20, 64, 64), .white, radius: 14.4, smooth: true)
            icon.fill.gradient = vertical("#62B8FF", "#1A6CF0")
            return P.part([
                panel("Background", P.box(0, 0, 260, h), c, radius: 26),
                P.group("App Icon", [
                    icon.outlined(.hex("#FFFFFF40"), width: 0.5).casting(P.shadow(y: 1, blur: 3, .hex("#00000033"))),
                    P.icon("layers", .lucide, center: CGPoint(x: 52, y: 52), size: 36, .white, weight: 1.8).named("Glyph"),
                ]),
                P.paragraph(String(localized: "Delete “Holiday Photos”?"), name: "Title", x: 20, y: 100, width: 220, size: 13, weight: "Bold", color: c.label),
                P.paragraph(message, name: "Message", x: 20, y: 126, width: 220, size: 13, color: c.label),
                P.group("Buttons", [
                    capsuleButton(String(localized: "Cancel"), P.box(16, h - 44, 110, 28), c, accent: false),
                    capsuleButton(String(localized: "Delete"), P.box(134, h - 44, 110, 28), c, accent: true),
                ]),
            ])
        }
    }()

    private enum MenuRow {
        case item(icon: String?, title: String, shortcut: String?, submenu: Bool, checked: Bool, highlighted: Bool)
        case separator
    }

    private static func menuRows() -> [MenuRow] {
        [
            .item(icon: "app-window", title: String(localized: "New Window"), shortcut: "⌘N", submenu: false, checked: false, highlighted: false),
            .item(icon: "folder-open", title: String(localized: "Open…"), shortcut: "⌘O", submenu: false, checked: false, highlighted: false),
            .item(icon: "clock", title: String(localized: "Open Recent"), shortcut: nil, submenu: true, checked: false, highlighted: false),
            .separator,
            .item(icon: "copy", title: String(localized: "Duplicate"), shortcut: "⇧⌘S", submenu: false, checked: false, highlighted: true),
            .item(icon: "pencil", title: String(localized: "Rename…"), shortcut: nil, submenu: false, checked: false, highlighted: false),
            .item(icon: "file-text", title: String(localized: "Export as PDF…"), shortcut: nil, submenu: false, checked: false, highlighted: false),
            .separator,
            .item(icon: nil, title: String(localized: "Show Sidebar"), shortcut: "⌃⌘S", submenu: false, checked: true, highlighted: false),
            .item(icon: nil, title: String(localized: "Show Toolbar"), shortcut: "⌥⌘T", submenu: false, checked: false, highlighted: false),
        ]
    }

    static let menu = Component(id: "macos.menu", title: "Menu", size: CGSize(width: 260, height: 228)) { look in
        let c = Palette(dark: look.dark)
        let w: CGFloat = 260
        var rows: [Node] = []
        var y: CGFloat = 6
        for row in menuRows() {
            switch row {
            case .separator:
                rows.append(P.rule(x: 14, y: y + 5.5, width: w - 28, c.separator, thickness: 1))
                y += 12
            case let .item(icon, title, shortcut, submenu, checked, highlighted):
                let r = P.box(6, y, w - 12, 24)
                let ink = highlighted ? RGBA.white : c.label
                let quiet = highlighted ? RGBA.white.with(alpha: 0.8) : c.secondary
                var item: [Node] = []
                if highlighted { item.append(P.rect("Highlight", r, c.accent, radius: 7)) }
                if checked {
                    item.append(P.icon("check", .lucide, center: CGPoint(x: 23, y: r.midY), size: 13, ink, weight: 3).named("Check"))
                } else if let icon {
                    item.append(P.icon(icon, .lucide, center: CGPoint(x: 23, y: r.midY), size: 15, ink, weight: 1.9).named("Icon"))
                }
                item.append(P.text(title, name: "Title", in: P.box(38, y, 170, 24), size: 13, color: ink))
                if let shortcut {
                    item.append(P.text(shortcut, name: "Shortcut", in: P.box(0, y, w - 18, 24), size: 13, color: quiet, align: .right))
                }
                if submenu {
                    item.append(P.icon("chevron-right", .lucide, center: CGPoint(x: w - 23, y: r.midY), size: 12, ink, weight: 2.8).named("Submenu"))
                }
                rows.append(P.group(title, item))
                y += 24
            }
        }
        return P.part([
            panel("Background", P.box(0, 0, w, y + 6), c, radius: 12),
            P.group("Items", rows),
        ])
    }

    static let popover = Component(id: "macos.popover", title: "Popover", size: CGSize(width: 280, height: 186)) { look in
        let c = Palette(dark: look.dark)
        let w: CGFloat = 280, h: CGFloat = 186, a: CGFloat = 11
        let body = bubble(w: w, h: h, radius: 16, arrow: a)
        var shape = P.shape("Background", body, box: P.box(0, 0, w, h), in: P.box(0, 0, w, h), c.panel)
        shape = shape.frosted(30, tint: 1).outlined(c.panelRim, width: 0.5)
            .casting(P.shadow(y: 10, blur: 32, c.panelShadow), P.shadow(y: 0, blur: 1.5, c.panelRim))
        func detail(_ icon: String, _ s: String, _ y: CGFloat) -> Node {
            P.group(s, [
                P.icon(icon, .lucide, center: CGPoint(x: 26, y: y + 8), size: 14, c.secondary, weight: 2).named("Icon"),
                P.text(s, name: "Label", in: P.box(40, y, 220, 16), size: 13, color: c.secondary),
            ])
        }
        return P.part([
            shape,
            P.text(String(localized: "Team Meeting"), name: "Title", x: 18, y: a + 15, size: 15, weight: "Bold", color: c.label),
            P.group("Details", [
                detail("calendar", String(localized: "Tuesday, 4 November"), a + 44),
                detail("clock", String(localized: "10:00 to 11:00"), a + 66),
                detail("map-pin", String(localized: "Room 4"), a + 88),
            ]),
            P.rule(x: 18, y: a + 117, width: w - 36, c.separator, thickness: 1),
            P.group("Buttons", [
                pushButton(String(localized: "Decline"), P.box(w - 18 - 80 - 8 - 80, a + 133, 80, 24), c, accent: false),
                pushButton(String(localized: "Accept"), P.box(w - 18 - 80, a + 133, 80, 24), c, accent: true),
            ]),
        ])
    }

    static let tooltip: Component = {
        let label = String(localized: "Hide or show the sidebar")
        let width = (P.width(of: label, size: 11) + 16).rounded(.up)
        return Component(id: "macos.tooltip", title: "Tooltip", size: CGSize(width: width, height: 22)) { look in
            let c = Palette(dark: look.dark)
            let r = P.box(0, 0, width, 22)
            return P.part([
                P.rect("Background", r, look.dark ? .hex("#2C2C2E") : .hex("#F7F7F7"), radius: 6)
                    .outlined(c.panelRim, width: 0.5)
                    .casting(P.shadow(y: 2, blur: 8, look.dark ? .hex("#00000066") : .hex("#00000026"))),
                P.text(label, name: "Label", in: r, size: 11, color: c.label, align: .center),
            ])
        }
    }()

    /// The columns of the table: their titles and widths.
    private static let columns: [(String, CGFloat)] = [("Name", 190), ("Date Modified", 140), ("Size", 70), ("Kind", 120)]

    static let table = Component(id: "macos.table", title: "Table", size: CGSize(width: 520, height: 172)) { look in
        let c = Palette(dark: look.dark)
        let w: CGFloat = 520
        let titles = [String(localized: "Name"), String(localized: "Date Modified"), String(localized: "Size"), String(localized: "Kind")]
        var header: [Node] = [P.rect("Background", P.box(0, 0, w, 28), c.window)]
        var x: CGFloat = 0
        for (i, (_, width)) in columns.enumerated() {
            header.append(P.text(titles[i], name: titles[i], in: P.box(x + (i == 0 ? 16 : 10), 0, width, 28), size: 11, weight: "Medium", color: c.label))
            if i > 0 { header.append(P.rect("Divider", P.box(x, 6, 1, 16), c.separator)) }
            x += width
        }
        header.append(P.rule("Separator", x: 0, y: 27, width: w, c.separator, thickness: 1))
        let files: [(icon: String, name: String, date: String, size: String, kind: String)] = [
            ("folder", String(localized: "Projects"), String(localized: "Today, 09:41"), "1.2 GB", String(localized: "Folder")),
            ("PDF", String(localized: "Report.pdf"), String(localized: "Yesterday, 16:20"), "2.4 MB", String(localized: "PDF document")),
            ("CSV", String(localized: "Budget.csv"), String(localized: "3 Nov 2026"), "18 KB", String(localized: "CSV document")),
            ("PNG", String(localized: "Cover.png"), String(localized: "28 Oct 2026"), "4.1 MB", String(localized: "PNG image")),
            ("TXT", String(localized: "Notes.txt"), String(localized: "21 Oct 2026"), "3 KB", String(localized: "Plain text")),
            ("folder", String(localized: "Archive"), String(localized: "2 Oct 2026"), "860 MB", String(localized: "Folder")),
        ]
        let selected = 1
        var rows: [Node] = []
        for (i, f) in files.enumerated() {
            let y = 28 + CGFloat(i) * 24
            let on = i == selected
            let ink = on ? RGBA.white : c.label, quiet = on ? RGBA.white.with(alpha: 0.85) : c.secondary
            var row: [Node] = []
            if on {
                row.append(P.rect("Selection", P.box(6, y, w - 12, 24), c.selection, radius: 6))
            } else {
                row.append(P.rect("Background", P.box(0, y, w, 24), i % 2 == 1 ? c.stripe : c.window))
            }
            if f.icon == "folder" {
                row.append(folder(CGPoint(x: 24, y: y + 12), size: 18, dark: look.dark))
            } else {
                row.append(smallPage(CGPoint(x: 24, y: y + 12)))
            }
            var cx: CGFloat = columns[0].1
            row.append(P.text(f.name, name: "Name", in: P.box(38, y, 150, 24), size: 13, color: ink))
            row.append(P.text(f.date, name: "Date Modified", in: P.box(cx + 10, y, 130, 24), size: 13, color: quiet))
            cx += columns[1].1
            row.append(P.text(f.size, name: "Size", in: P.box(cx + 10, y, 60, 24), size: 13, color: quiet))
            cx += columns[2].1
            row.append(P.text(f.kind, name: "Kind", in: P.box(cx + 10, y, 110, 24), size: 13, color: quiet))
            rows.append(P.group(f.name, row))
        }
        return P.part([
            P.group("Header", header),
            P.group("Rows", rows),
        ])
    }

    /// The tabs of a tab view: their words and widths.
    private static func tabs() -> [(String, CGFloat)] {
        [String(localized: "General"), String(localized: "Advanced"), String(localized: "Sharing")]
            .map { ($0, (P.width(of: $0, size: 13) + 24).rounded()) }
    }

    static let tabView = Component(id: "macos.tab-view", title: "Tab View", size: CGSize(width: 420, height: 200)) { look in
        let c = Palette(dark: look.dark)
        let w: CGFloat = 420
        let tabs = tabs()
        let trackWidth = tabs.reduce(0) { $0 + $1.1 } + 4
        var x = ((w - trackWidth) / 2).rounded() + 2
        var bar: [Node] = [P.rect("Track", P.box(x - 2, 0, trackWidth, 24), look.dark ? .hex("#3A3A3C") : .hex("#EDEDED"), radius: 7)]
        for (i, (word, width)) in tabs.enumerated() {
            var tab: [Node] = []
            if i == 0 {
                tab.append(P.rect("Selection", P.box(x, 2, width, 20), look.dark ? .hex("#636366") : .white, radius: 5)
                    .casting(P.shadow(y: 0.5, blur: 2, c.knobShadow)))
            }
            tab.append(P.text(word, name: "Label", in: P.box(x, 0, width, 24), size: 13, weight: i == 0 ? "Medium" : "Regular", color: c.label, align: .center))
            bar.append(P.group(word, tab))
            x += width
        }
        let options = P.group("Options", [
            checkboxOn.make(look).named(String(localized: "Show in menu bar")).moved(24, 48),
            checkboxOff.make(look).named(String(localized: "Open at login")).moved(24, 76),
            P.text(String(localized: "Appearance:"), name: "Label", in: P.box(24, 112, 120, 24), size: 13, color: c.label),
            popUpButton.make(look).named(String(localized: "Appearance")).moved(24 + P.width(of: String(localized: "Appearance:"), size: 13) + 8, 112),
        ])
        return P.part([
            P.rect("Box", P.box(0, 12, w, 188), c.box, radius: 10).outlined(c.separator, width: 1),
            options,
            P.group("Tabs", bar),
        ])
    }

    static let notification = Component(id: "macos.notification", title: "Notification", size: CGSize(width: 360, height: 68)) { look in
        let c = Palette(dark: look.dark)
        let w: CGFloat = 360
        return P.part([
            panel("Background", P.box(0, 0, w, 68), c, radius: 20),
            appTile("App Icon", P.box(14, 15, 38, 38), top: "#FFFFFF", bottom: "#ECECEF", glyph: "calendar", ink: .hex("#FF3B30")),
            P.text(String(localized: "Team Meeting"), name: "Title", x: 64, y: 15, size: 13, weight: "Bold", color: c.label),
            P.text(String(localized: "now"), name: "Time", x: w - 16, y: 16, size: 11, color: c.secondary, align: .right),
            P.text(String(localized: "Starts in 10 minutes in Room 4"), name: "Message", x: 64, y: 35, size: 13, color: c.label),
        ])
    }

    // MARK: - Making parts

    /// A control with a word beside it, as wide as both.
    private static func labelled(_ id: String, _ title: LocalizedStringResource, _ label: String, _ control: @escaping @Sendable (Palette) -> Node) -> Component {
        let width = 22 + P.width(of: label, size: 13)
        return Component(id: id, title: title, size: CGSize(width: width, height: 16)) { look in
            let c = Palette(dark: look.dark)
            return P.part([
                control(c),
                P.text(label, name: "Label", in: P.box(22, 0, 400, 16), size: 13, color: c.label),
            ])
        }
    }

    private static func pushButton(_ label: String, _ r: CGRect, _ c: Palette, accent: Bool) -> Node {
        P.group(label, [
            P.rect("Background", r, accent ? c.accent : c.control, radius: 6),
            P.text(label, name: "Label", in: r, size: 13, color: accent ? .white : c.label, align: .center),
        ])
    }

    private static func capsuleButton(_ label: String, _ r: CGRect, _ c: Palette, accent: Bool) -> Node {
        P.group(label, [
            P.pill("Background", r, accent ? c.accent : c.control),
            P.text(label, name: "Label", in: r, size: 13, weight: accent ? "Medium" : "Regular", color: accent ? .white : c.label, align: .center),
        ])
    }

    /// A switch's or a slider's knob: white, round, lifted a little.
    private static func knob(_ r: CGRect, _ c: Palette) -> Node {
        P.pill("Knob", r, .white).casting(P.shadow(y: 0, blur: 1.5, c.knobShadow), P.shadow(y: 1, blur: 3, c.knobShadow.with(alpha: c.knobShadow.a * 0.6)))
    }

    /// Close, minimise and zoom: red, yellow and green, 14 points across.
    private static func lights(x: CGFloat, y: CGFloat) -> Node {
        let specs: [(String, String, String)] = [("Close", "#FF5F57", "#E0443E"), ("Minimize", "#FEBC2E", "#DEA123"), ("Zoom", "#28C840", "#1AAB29")]
        var dots: [Node] = []
        for (i, spec) in specs.enumerated() {
            dots.append(P.oval(spec.0, P.box(x + CGFloat(i) * 23, y, 14, 14), .hex(spec.1)).outlined(.hex(spec.2), width: 0.5))
        }
        return P.group("Traffic Lights", dots)
    }

    /// A round button of glass with an icon.
    private static func glassButton(_ name: String, _ icon: String, _ r: CGRect, _ c: Palette) -> Node {
        P.group(name, [
            glass("Glass", r, c),
            P.icon(icon, .lucide, center: CGPoint(x: r.midX, y: r.midY - 0.5), size: 18, c.label, weight: 1.7).named("Icon"),
        ])
    }

    private static func glass(_ name: String, _ r: CGRect, _ c: Palette) -> Node {
        P.pill(name, r, c.glass).frosted(12, tint: 1).outlined(c.glassRim, width: 0.5)
            .casting(P.shadow(y: 2, blur: 10, c.glassShadow))
    }

    /// Back and forward, in one capsule of glass.
    private static func navigation(x: CGFloat, _ c: Palette) -> Node {
        let r = P.box(x, 8, 80, 36)
        return P.group("Navigation", [
            glass("Glass", r, c),
            P.icon("chevron-left", .lucide, center: CGPoint(x: r.minX + 21, y: r.midY), size: 20, c.label, weight: 1.8).named("Back"),
            P.rect("Divider", P.box(r.midX - 0.5, r.minY + 10, 1, 16), c.separator),
            P.icon("chevron-right", .lucide, center: CGPoint(x: r.maxX - 21, y: r.midY), size: 20, c.tertiary, weight: 1.8).named("Forward"),
        ])
    }

    /// A capsule of glass holding icons side by side, the first one chosen.
    private static func viewGroup(_ r: CGRect, _ c: Palette, items: [String]) -> Node {
        let each = (r.width - 4) / CGFloat(items.count)
        var layers: [Node] = [glass("Glass", r, c)]
        for (i, icon) in items.enumerated() {
            let x = r.minX + 2 + each * CGFloat(i)
            if i == 0 { layers.append(P.pill("Selection", P.box(x + 2, r.minY + 4, each - 4, r.height - 8), c.glassSelected)) }
            layers.append(P.icon(icon, .lucide, center: CGPoint(x: x + each / 2, y: r.midY), size: 18, c.label, weight: 1.7).named("Icon"))
        }
        return P.group("View", layers)
    }

    private static func searchCapsule(_ r: CGRect, _ c: Palette) -> Node {
        P.group("Search", [
            glass("Glass", r, c),
            P.icon("search", .lucide, center: CGPoint(x: r.minX + 19, y: r.midY), size: 16, c.secondary, weight: 2.2).named("Magnifier"),
            P.text(String(localized: "Search"), name: "Placeholder", in: P.box(r.minX + 34, r.minY, r.width - 40, r.height), size: 13, color: c.secondary),
        ])
    }

    /// A folder's icon: its back with the tab, and its front, a lighter blue.
    private static func folder(_ center: CGPoint, size s: CGFloat, dark: Bool) -> Node {
        let box = CGRect(x: center.x - s / 2, y: center.y - s / 2, width: s, height: s)
        return P.group("Icon", [
            P.icon("folder", .material, box, dark ? .hex("#3D8FDE") : .hex("#4CA3EE"), style: 1).named("Back"),
            P.rect("Front", P.box(box.minX + s / 12, box.minY + s * 0.33, s * 10 / 12, s * (5.0 / 6 - 0.33)),
                   dark ? .hex("#5BABF2") : .hex("#70BEF9"), radius: s / 12),
        ])
    }

    /// The source list of a window, floating in glass: the traffic lights at its top, then its
    /// sections, one row chosen.
    private static func sidebarPanel(_ r: CGRect, _ c: Palette) -> Node {
        var layers: [Node] = [
            P.rect("Glass", r, c.sidebar, radius: 14, smooth: true).frosted(24, tint: 1).outlined(c.sidebarRim, width: 0.5)
                .casting(P.shadow(y: 1, blur: 8, c.dark ? .hex("#00000066") : .hex("#0000000F"))),
            lights(x: r.minX + 11, y: r.minY + 11),
            P.icon("panel-left", .lucide, center: CGPoint(x: r.maxX - 22, y: r.minY + 18), size: 18, c.secondary, weight: 1.7).named("Sidebar Button"),
        ]
        let x = r.minX + 8, w = r.width - 16
        var y = r.minY + 48
        let sections: [(String, [(String, String)])] = [
            (String(localized: "Favourites"), [("clock", String(localized: "Recents")), ("layout-grid", String(localized: "Applications")),
                                              ("monitor", String(localized: "Desktop")), ("file-text", String(localized: "Documents")),
                                              ("circle-arrow-down", String(localized: "Downloads"))]),
            (String(localized: "Locations"), [("cloud", "iCloud Drive"), ("globe", String(localized: "Network"))]),
            (String(localized: "Tags"), [("#FF5F57", String(localized: "Red")), ("#FEBC2E", String(localized: "Orange")), ("#34C759", String(localized: "Green"))]),
        ]
        let chosen = String(localized: "Documents")
        for (title, rows) in sections {
            var section: [Node] = [P.text(title, name: "Header", x: x + 8, y: y, size: 11, weight: "Semibold", color: c.tertiary)]
            y += 19
            for (icon, label) in rows {
                let on = label == chosen
                var row: [Node] = []
                if on { row.append(P.rect("Selection", P.box(x, y, w, 24), c.selection, radius: 8)) }
                if icon.hasPrefix("#") {
                    row.append(P.oval("Tag", P.box(x + 11, y + 7, 10, 10), .hex(icon)))
                } else {
                    row.append(P.icon(icon, .lucide, center: CGPoint(x: x + 16, y: y + 12), size: 16, on ? .white : c.accent, weight: 1.8).named("Icon"))
                }
                row.append(P.text(label, name: "Label", in: P.box(x + 30, y, w - 34, 24), size: 13, weight: on ? "Semibold" : "Regular", color: on ? .white : c.label))
                section.append(P.group(label, row))
                y += 24
            }
            y += 12
            layers.append(P.group(title, section))
        }
        return P.group("Sidebar", layers)
    }

    /// A window's files as icons: folders, and pages with their kind on them, one of them chosen.
    private static func files(x: CGFloat, y: CGFloat, _ c: Palette) -> [Node] {
        let items: [(String, String)] = [("folder", String(localized: "Projects")), ("folder", String(localized: "Invoices")),
                                         ("folder", String(localized: "Photos")), ("folder", String(localized: "Archive")),
                                         ("PDF", String(localized: "Report.pdf")), ("CSV", String(localized: "Budget.csv")),
                                         ("PNG", String(localized: "Cover.png")), ("TXT", String(localized: "Notes.txt"))]
        let chosen = 2
        var nodes: [Node] = []
        for (i, (kind, name)) in items.enumerated() {
            let cx = x + 50 + CGFloat(i % 6) * 104, top = y + CGFloat(i / 6) * 112
            var item: [Node] = []
            if i == chosen { item.append(P.rect("Highlight", P.box(cx - 38, top - 4, 76, 72), c.glassSelected, radius: 8)) }
            if kind == "folder" {
                item.append(folder(CGPoint(x: cx, y: top + 33), size: 72, dark: c.dark))
            } else {
                item.append(page(CGPoint(x: cx, y: top + 32), kind: kind, c))
            }
            var label = P.text(name, name: "Name", x: cx, y: top + 72, size: 12, color: i == chosen ? .white : c.label, align: .center)
            if i == chosen {
                let f = label.frame
                item.append(P.rect("Name Highlight", P.box(f.minX - 5, f.minY, f.width + 10, f.height + 1), c.selection, radius: 4))
                label.name = "Name"
            }
            item.append(label)
            nodes.append(P.group(name, item))
        }
        return nodes
    }

    /// A document's icon: a white page, lines of text on it, and its kind.
    private static func page(_ center: CGPoint, kind: String, _ c: Palette) -> Node {
        let r = P.box(center.x - 22, center.y - 29, 44, 58)
        var lines: [Node] = []
        for i in 0..<5 {
            lines.append(P.rect("Line", P.box(r.minX + 8, r.minY + 10 + CGFloat(i) * 5, i == 4 ? 18 : 28, 1.5), .hex("#0000001F")))
        }
        let tint: RGBA = kind == "PDF" ? .hex("#E5483C") : kind == "PNG" ? .hex("#7B61D9") : kind == "CSV" ? .hex("#2E9E5B") : .hex("#8E8E93")
        return P.group("Icon", [
            P.rect("Page", r, .white, radius: 4).outlined(.hex("#00000024"), width: 0.5)
                .casting(P.shadow(y: 0.5, blur: 1.5, c.dark ? .hex("#00000080") : .hex("#00000024"))),
            P.group("Text", lines),
            P.text(kind, name: "Kind", in: P.box(r.minX, r.maxY - 19, r.width, 12), size: 9, weight: "Bold", color: tint, align: .center),
        ])
    }

    /// A document's icon at the size of a list's row.
    private static func smallPage(_ center: CGPoint) -> Node {
        let r = P.box(center.x - 6, center.y - 8, 12, 16)
        return P.group("Icon", [
            P.rect("Page", r, .white, radius: 2).outlined(.hex("#00000033"), width: 0.5),
            P.rect("Line", P.box(r.minX + 3, r.minY + 4, 6, 1), .hex("#00000033")),
            P.rect("Line", P.box(r.minX + 3, r.minY + 7, 6, 1), .hex("#00000033")),
            P.rect("Line", P.box(r.minX + 3, r.minY + 10, 4, 1), .hex("#00000033")),
        ])
    }

    /// An app's icon as a rounded square of colour with a glyph: never a real app's.
    private static func appTile(_ name: String, _ r: CGRect, top: String, bottom: String, glyph: String, ink: RGBA) -> Node {
        var tile = P.rect("Tile", r, .hex(top), radius: r.width * 0.225, smooth: true)
        tile.fill.gradient = vertical(top, bottom)
        return P.group(name, [
            tile.outlined(.hex("#0000001A"), width: 0.5).casting(P.shadow(y: 1, blur: 3, .hex("#00000033"))),
            P.icon(glyph, .lucide, center: CGPoint(x: r.midX, y: r.midY), size: r.width * 0.54, ink, weight: 1.8).named("Glyph"),
        ])
    }

    private static func vertical(_ top: String, _ bottom: String) -> Gradient {
        Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: .hex(top)), GradientStop(offset: 1, color: .hex(bottom))],
                 start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1))
    }

    /// A panel of glass floating over everything: a menu, an alert, a notification.
    private static func panel(_ name: String, _ r: CGRect, _ c: Palette, radius: CGFloat) -> Node {
        P.rect(name, r, c.panel, radius: radius, smooth: true).frosted(30, tint: 1).outlined(c.panelRim, width: 0.5)
            .casting(P.shadow(y: 10, blur: 32, c.panelShadow), P.shadow(y: 0, blur: 1.5, c.panelRim))
    }

    /// A popover's outline: a rounded box with an arrow on top, pointing up from its middle.
    private static func bubble(w: CGFloat, h: CGFloat, radius r: CGFloat, arrow a: CGFloat) -> String {
        let m = w / 2, half: CGFloat = 13
        func n(_ v: CGFloat) -> String { String(format: "%.2f", v) }
        return "M\(n(r)) \(n(a))H\(n(m - half))C\(n(m - half + 6)) \(n(a)) \(n(m - 3.5)) 0 \(n(m)) 0C\(n(m + 3.5)) 0 \(n(m + half - 6)) \(n(a)) \(n(m + half)) \(n(a))"
            + "H\(n(w - r))A\(n(r)) \(n(r)) 0 0 1 \(n(w)) \(n(a + r))V\(n(h - r))A\(n(r)) \(n(r)) 0 0 1 \(n(w - r)) \(n(h))"
            + "H\(n(r))A\(n(r)) \(n(r)) 0 0 1 0 \(n(h - r))V\(n(a + r))A\(n(r)) \(n(r)) 0 0 1 \(n(r)) \(n(a))Z"
    }

    /// Control Centre's sign in the menu bar: two switches, one on and one off.
    private static func controlCentre(_ c: CGPoint, ink: RGBA) -> Node {
        let w: CGFloat = 15, h: CGFloat = 6.4, x = c.x - w / 2
        let top = P.box(x, c.y - h - 0.8, w, h), bottom = P.box(x, c.y + 0.8, w, h)
        return P.group("Control Centre", [
            P.pill("Top", top, .hex("#00000000")).outlined(ink, width: 1.2),
            P.oval("Top Knob", P.box(top.minX + 1.9, top.minY + 1.5, 3.4, 3.4), ink),
            P.pill("Bottom", bottom, .hex("#00000000")).outlined(ink, width: 1.2),
            P.oval("Bottom Knob", P.box(bottom.maxX - 1.9 - 3.4, bottom.minY + 1.5, 3.4, 3.4), ink),
        ])
    }

    /// The battery in the menu bar: its outline, how full it is, and its cap.
    private static func battery(x: CGFloat, y: CGFloat, _ c: Palette, ink: RGBA) -> Node {
        P.group("Battery", [
            P.rect("Edge", P.box(x, y, 24, 12), .hex("#00000000"), radius: 3.5).outlined(ink.with(alpha: 0.4), width: 1),
            P.rect("Level", P.box(x + 2, y + 2, 15, 8), ink, radius: 1.8),
            P.rect("Cap", P.box(x + 25, y + 4, 1.6, 4), ink.with(alpha: 0.45), corners: [0, 1, 1, 0]),
        ])
    }
}
