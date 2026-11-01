import SwiftUI
import AppKit

// MARK: - Starting a design

/// The top of the home screen. The greeting, in the middle, asks what is to be designed; under it
/// a table lit as the room is at this time of day, with every family of sizes along its top edge
/// and the open family standing on it: each size as the thing it is for, a phone, a laptop, a
/// story, a sheet of A4, all at one scale, so they are as large beside each other as they really
/// are. Pointing at one lifts it and tips it towards the pointer; a click starts a design that
/// size. The last tab puts one sheet of your own on the table, to type a size for or to pull by
/// its corner.
struct StartArea: View {
    let appeared: Bool
    /// Starts a design with one artboard of a size and name; given a slide's size too, the
    /// artboard is a carousel of such slides.
    let create: (CGSize, String, CGSize?) -> Void
    @AppStorage("home.width", store: Library.settings) private var width: Double = Preset.standard.size.width
    @AppStorage("home.height", store: Library.settings) private var height: Double = Preset.standard.size.height
    @AppStorage("home.family", store: Library.settings) private var openName = Preset.standard.group.rawValue
    @Namespace private var chip

    /// The family on the table.
    private var open: Family { Family(key: openName) }

    var body: some View {
        let light = Daylight.at(.now)
        VStack(spacing: 0) {
            greeting
                .rising(appeared, order: 0)
                .padding(.bottom, 26)
            VStack(spacing: 0) {
                FamilyTabs(open: open, chip: chip) { choose($0) }
                    .padding(.top, 14)
                ZStack {
                    if open == .own {
                        OwnSizeStage(width: $width, height: $height, light: light) {
                            create(CGSize(width: width.rounded(), height: height.rounded()), String(localized: "Artboard"), nil)
                        }
                        .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.05)),
                                                removal: .opacity.animation(.easeOut(duration: 0.1))))
                    } else {
                        Lineup(picks: open.picks, widest: open.widest, light: light) { pick in
                            if pick.slides > 1 {
                                create(pick.artboard, String(localized: "Carousel"), pick.size)
                            } else {
                                create(pick.size, String(localized: pick.title), nil)
                            }
                        }
                        .id(open)
                        .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: 0.1))))
                    }
                }
            }
            .background { Stage(light: light) }
            .rising(appeared, order: 1)
        }
    }

    /// Good evening, and what is to be designed, on one line where there is room for both.
    private var greeting: some View {
        let hello = Text(HomeView.greeting(at: .now)).foregroundStyle(Theme.ink)
        let question = Text("What are you designing today?").foregroundStyle(Theme.ink3)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 11) {
                hello
                question
            }
            VStack(spacing: 2) {
                hello
                question
            }
        }
        .font(Theme.serif(34, weight: .medium))
        .lineLimit(1)
        .frame(maxWidth: .infinity)
    }

    private func choose(_ family: Family) {
        guard family.key != openName else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { openName = family.key }
    }
}

/// What can be on the table: a family of presets, the carousel formats, or a size of your own.
private enum Family: Hashable {
    case group(Preset.Group)
    case carousels
    case own

    /// What it is remembered as.
    var key: String {
        switch self {
        case .group(let group): group.rawValue
        case .carousels: "carousels"
        case .own: "own"
        }
    }

    init(key: String) {
        switch key {
        case Family.carousels.key: self = .carousels
        case Family.own.key: self = .own
        default: self = .group(Preset.Group(rawValue: key) ?? Preset.standard.group)
        }
    }

    /// What stands on the table for it.
    var picks: [Pick] {
        switch self {
        case .group(let group): Preset.all(in: group).map(Pick.init)
        case .carousels: Carousel.formats.map(Pick.init)
        case .own: []
        }
    }

    /// How wide the widest thing stands. Carousels, all as wide as their slides, stand a little
    /// narrower so that the four of them fit side by side.
    var widest: CGFloat { self == .carousels ? 190 : 230 }
}

/// One thing standing on the table: a preset, or a carousel format at as many slides as a new
/// carousel has.
private struct Pick: Identifiable {
    let id: String
    let title: LocalizedStringResource
    /// The artboard's size, or a carousel's slide's: what is written under it.
    let size: CGSize
    var slides = 1
    let form: SizeForm

    init(_ preset: Preset) {
        id = preset.id
        title = preset.title
        size = preset.size
        form = .of(preset)
    }

    init(_ format: Carousel.Format) {
        id = "carousel " + format.id
        title = format.title
        size = format.size
        slides = Carousel.startingCount
        form = .carousel(slides: Carousel.startingCount)
    }

    /// The whole artboard: every slide of a carousel side by side.
    var artboard: CGSize { CGSize(width: size.width * CGFloat(slides), height: size.height) }

    /// How large it stands beside the rest of its family, as it is in the hand.
    var drawn: CGSize { CGSize(width: artboard.width * form.density, height: artboard.height * form.density) }
}

// MARK: The table

/// The table the sizes stand on, lit from where the light in the room would be: daylight from the
/// left in the morning, overhead at noon, low and warm from the right towards evening, and at night
/// a lamp's pool. What stands on it casts its shadow away from the light.
struct Daylight {
    /// Where the light falls from, across the table: 0 at the left, 1 at the right.
    let x: CGFloat
    /// How warm it is: 0 cool daylight, 1 lamplight.
    let warmth: CGFloat
    /// Whether it is a lamp, after dark.
    let lamp: Bool

    static func at(_ date: Date) -> Daylight {
        let calendar = Calendar.current
        var hour = CGFloat(calendar.component(.hour, from: date)) + CGFloat(calendar.component(.minute, from: date)) / 60
        #if DEBUG
        // BEZZLE_HOME_HOUR=9.5 lights the table as at that hour, to see it in a snapshot.
        if let forced = ProcessInfo.processInfo.environment["BEZZLE_HOME_HOUR"].flatMap(Double.init) { hour = CGFloat(forced) }
        #endif
        guard (6..<20).contains(hour) else { return Daylight(x: 0.8, warmth: 1, lamp: true) }
        let day = (hour - 6) / 14
        return Daylight(x: 0.14 + day * 0.72, warmth: max(0, day - 0.45) * 1.6, lamp: false)
    }

    /// How far shadows fall sideways, away from the light.
    var lean: CGFloat { (0.5 - x) * 9 }

    func color(dark: Bool) -> Color {
        // Cool daylight to warm lamplight.
        let cool = (r: 0.92, g: 0.95, b: 1.0), warm = (r: 1.0, g: 0.84, b: 0.64)
        let t = Double(min(max(warmth, 0), 1))
        return Color(red: cool.r + (warm.r - cool.r) * t, green: cool.g + (warm.g - cool.g) * t, blue: cool.b + (warm.b - cool.b) * t)
    }

    func strength(dark: Bool) -> Double {
        dark ? (lamp ? 0.13 : 0.075) : (lamp ? 0.5 : 0.62)
    }
}

/// The table itself: pressed into the paper, a pool of light on it.
private struct Stage: View {
    let light: Daylight
    @Environment(\.colorScheme) private var scheme

    static let radius: CGFloat = 20

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        let dark = scheme == .dark
        shape
            .fill(Color(nsColor: CanvasInk.table))
            .overlay {
                EllipticalGradient(colors: [light.color(dark: dark).opacity(light.strength(dark: dark)), light.color(dark: dark).opacity(0)],
                                   center: UnitPoint(x: light.x, y: light.lamp ? 0.25 : 0), startRadiusFraction: 0, endRadiusFraction: light.lamp ? 0.62 : 0.85)
                    .clipShape(shape)
            }
            .overlay {
                // The far edge of the table falls away into shade.
                LinearGradient(colors: [.clear, Color.black.opacity(dark ? 0.16 : 0.035)], startPoint: .center, endPoint: .bottom)
                    .clipShape(shape)
            }
            .overlay { TableRim(radius: Self.radius) }
    }
}

// MARK: The families

/// Every family of sizes by name, along the top of the table: devices, then platforms and
/// carousels, then paper and slides, a hairline between them, and last a size of your own. The
/// open one rests on a card, as the window's tab in front does, and the card slides along to the
/// one picked. Where the window is too narrow for them all, the row scrolls.
private struct FamilyTabs: View {
    let open: Family
    let chip: Namespace.ID
    let choose: (Family) -> Void
    @State private var room: CGFloat = 900

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(Array(Preset.Kind.allCases.enumerated()), id: \.element) { i, kind in
                        if i > 0 { divider }
                        ForEach(Preset.Group.all(of: kind), id: \.self) { group in
                            tab(group.title, .group(group))
                        }
                        if kind == .social { tab("Carousels", .carousels) }
                    }
                    divider
                    tab("Your own size", .own)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .frame(minWidth: room)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .sideFade(length: 24)
            // The open family kept in sight where the row is too narrow for them all, scrolled
            // to only as far as it takes, once the row is laid out at its new width.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                room = width
                DispatchQueue.main.async { reader.scrollTo(open.key) }
            }
        }
    }

    private func tab(_ title: LocalizedStringResource, _ family: Family) -> some View {
        FamilyTab(title: title, open: open == family, chip: chip) { choose(family) }
            .id(family.key)
    }

    private var divider: some View {
        Hairline(vertical: true)
            .frame(height: 13)
            .padding(.horizontal, 7)
    }
}

private struct FamilyTab: View {
    let title: LocalizedStringResource
    let open: Bool
    let chip: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(open ? Theme.ink : hovering ? Theme.ink.opacity(0.8) : Theme.ink2)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background {
                    if open {
                        Capsule()
                            .fill(Theme.card)
                            .shadow(color: Theme.shadow.opacity(0.16), radius: 3, y: 1)
                            .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5) }
                            .matchedGeometryEffect(id: "chip", in: chip)
                    } else if hovering {
                        Capsule().fill(Theme.ink.opacity(0.05))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

// MARK: The sizes

/// The open family's sizes standing in a row in the middle of the table, at one scale.
private struct Lineup: View {
    let picks: [Pick]
    /// How wide the widest thing stands.
    let widest: CGFloat
    let light: Daylight
    let start: (Pick) -> Void
    @State private var room: CGFloat = 900

    /// How tall the tallest thing stands.
    static let tallest: CGFloat = 150
    static let gap: CGFloat = 26
    /// Room above for a thing to lift into, and under the names.
    static let above: CGFloat = 34
    static let below: CGFloat = 26

    var body: some View {
        let scale = Self.scale(for: picks, widest: widest)
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(Array(picks.enumerated()), id: \.element.id) { i, pick in
                    SizeStand(pick: pick, scale: scale, order: i, light: light) { start(pick) }
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, Self.above)
            .padding(.bottom, Self.below)
            .frame(minWidth: room)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .sideFade()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0 }
    }

    /// One scale for the whole family, as large as lets its tallest and widest thing fit.
    static func scale(for picks: [Pick], widest: CGFloat) -> CGFloat {
        let w = picks.map(\.drawn.width).max() ?? 1, h = picks.map(\.drawn.height).max() ?? 1
        let first = min(tallest / h, widest / w)
        var most = CGSize.zero
        for p in picks {
            let size = p.form.metrics(CGSize(width: p.drawn.width * first, height: p.drawn.height * first)).size
            most = CGSize(width: max(most.width, size.width), height: max(most.height, size.height))
        }
        return first * min(tallest / max(most.height, 1), widest / max(most.width, 1))
    }
}

/// A size standing on the table as the thing it is for, its name and its width and height under
/// it. It comes up onto the table in its turn as its family opens. Pointed at, it lifts and tips
/// towards the pointer, its screen outlined in pencil with a plus on it; a click starts a design
/// that size.
private struct SizeStand: View {
    let pick: Pick
    let scale: CGFloat
    /// Its place in the row, which sets how long it waits to come up.
    let order: Int
    let light: Daylight
    let start: () -> Void
    @State private var hovering = false
    /// Where the pointer is over it, from -0.5 to 0.5 each way.
    @State private var tilt = CGPoint.zero
    @State private var shown = false

    var body: some View {
        let form = pick.form, size = pick.size
        let screen = CGSize(width: max((pick.drawn.width * scale).rounded(), 8), height: max((pick.drawn.height * scale).rounded(), 8))
        let figure = form.metrics(screen).size
        let numbers = "\(Int(size.width)) × \(Int(size.height))"
        let slot = Self.slot(figure.width, title: String(localized: pick.title), numbers: numbers)
        let lifted = hovering || Self.forcedHover == order
        Button(action: start) {
            VStack(spacing: 14) {
                Figure(form: form, screen: screen, lifted: lifted, tilt: Self.forcedHover == order ? CGPoint(x: 0.35, y: -0.25) : tilt, light: light)
                    .frame(width: slot, height: Lineup.tallest, alignment: .bottom)
                    .onContinuousHover { phase in
                        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.82)) {
                            switch phase {
                            case .active(let p): tilt = CGPoint(x: p.x / slot - 0.5, y: p.y / Lineup.tallest - 0.5)
                            case .ended: tilt = .zero
                            }
                        }
                    }
                VStack(spacing: 2) {
                    Text(pick.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(lifted ? Theme.pencil : Theme.ink)
                    Text(verbatim: numbers)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(lifted ? Theme.pencil.opacity(0.75) : Theme.ink3)
                }
                .lineLimit(1)
                .frame(width: slot)
            }
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: lifted)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72).delay(0.04 + Double(order) * 0.045)) { shown = true }
        }
        .help("Start a design \(Int(size.width)) by \(Int(size.height))")
        .accessibilityLabel("\(String(localized: pick.title)), \(Int(size.width)) by \(Int(size.height))")
    }

    /// How wide a size's place in the row is: as wide as it stands or as its name, whichever is wider.
    static func slot(_ figure: CGFloat, title: String, numbers: String) -> CGFloat {
        let name = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
        let size = (numbers as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]).width
        return max(figure, min(max(name, size, 44), 180)).rounded(.up)
    }

    /// BEZZLE_HOME_HOVER=n (debug builds) shows the nth size pointed at, to see it in a snapshot.
    static let forcedHover: Int? = {
        #if DEBUG
        ProcessInfo.processInfo.environment["BEZZLE_HOME_HOVER"].flatMap(Int.init)
        #else
        nil
        #endif
    }()
}

/// The thing a size is for, standing on the table: its screen (or page) the size's shape at the
/// table's scale, what holds it drawn round it, its shadow on the table under it.
private struct Figure: View {
    let form: SizeForm
    let screen: CGSize
    let lifted: Bool
    let tilt: CGPoint
    let light: Daylight

    var body: some View {
        let m = form.metrics(screen)
        ZStack(alignment: .bottom) {
            // Where it touches the table.
            Ellipse()
                .fill(CanvasShadow.color.opacity(lifted ? 0.14 : 0.3))
                .frame(width: m.size.width * (lifted ? 0.96 : 0.86), height: min(max(m.size.width * 0.06, 4), 9))
                .blur(radius: lifted ? 6 : 2.5)
                .offset(x: light.lean, y: 3)
            ZStack(alignment: .topLeading) {
                FormDrawing(form: form, m: m)
                form.outline(m)
                    .stroke(Theme.pencil, lineWidth: 1.5)
                    .place(m.screen)
                    .opacity(lifted ? 1 : 0)
                if min(m.screen.width, m.screen.height) >= 30 {
                    // Scaled before it is put in place, so that it grows out of the screen's middle.
                    Circle()
                        .fill(Theme.pencil)
                        .overlay {
                            Image(systemName: "plus")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .shadow(color: Theme.pencil.opacity(0.4), radius: 4, y: 2)
                        .frame(width: 22, height: 22)
                        .scaleEffect(lifted ? 1 : 0.2)
                        .opacity(lifted ? 1 : 0)
                        .animation(lifted ? .spring(response: 0.3, dampingFraction: 0.55) : .easeOut(duration: 0.12), value: lifted)
                        .place(CGRect(x: m.screen.midX - 11, y: m.screen.midY - 11, width: 22, height: 22))
                }
            }
            .frame(width: m.size.width, height: m.size.height, alignment: .topLeading)
            .compositingGroup()
            .shadow(color: CanvasShadow.color.opacity(lifted ? 0.3 : 0.14), radius: lifted ? 14 : 3, x: light.lean * (lifted ? 1.2 : 0.4), y: lifted ? 12 : 2)
            .rotation3DEffect(.degrees(Double(tilt.y) * 14), axis: (x: 1, y: 0, z: 0), perspective: 0.55)
            .rotation3DEffect(.degrees(Double(tilt.x) * -16), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
            .offset(y: lifted ? -9 : 0)
        }
    }
}

// MARK: The things sizes are for

/// What a size is drawn as on the table.
enum SizeForm: Equatable {
    case phone(island: Bool)
    /// The iPhone Duo: open, a book held sideways, its fold down the middle; closed, a passport
    /// with a straight spine down its left and the rounded edge it opens by on its right.
    case foldable(open: Bool)
    case tablet
    case laptop
    case desktop(iMac: Bool)
    case browser
    case watch
    /// A story, reel, short or TikTok, the full height of a phone.
    case story(sideButtons: Bool)
    /// A cover, header or banner, with the profile's picture over its lower edge.
    case banner
    case video
    case post(roundness: CGFloat)
    case paper
    case businessCard
    case postcard
    case slide
    /// A carousel's slides side by side, what is on them running across the cuts.
    case carousel(slides: Int)

    static func of(_ preset: Preset) -> SizeForm {
        let name = preset.name, size = preset.size
        switch preset.group {
        case .iPhone: return name.hasPrefix("iPhone Duo") ? .foldable(open: name == "iPhone Duo, open") : .phone(island: true)
        case .android: return .phone(island: false)
        case .iPad: return .tablet
        case .mac: return name.hasPrefix("MacBook") ? .laptop : .desktop(iMac: name.hasPrefix("iMac"))
        case .web: return .browser
        case .watch: return .watch
        case .instagram, .tiktok, .youtube, .facebook, .linkedin, .x, .pinterest:
            let lower = name.lowercased()
            if lower.contains("banner") || lower.contains("cover") || lower.contains("header") { return .banner }
            if size.height / size.width >= 1.6 { return .story(sideButtons: preset.group == .tiktok || preset.group == .youtube) }
            if preset.group == .youtube { return .video }
            return .post(roundness: preset.group == .pinterest ? 0.07 : 0.012)
        case .print:
            if name == "Business card" { return .businessCard }
            if name == "Postcard" { return .postcard }
            return .paper
        case .slides: return .slide
        }
    }

    /// How large the thing is round a screen of `s`, where in it the screen lies, and how round
    /// the screen's corners are.
    func metrics(_ s: CGSize) -> FormMetrics {
        let w = s.width, h = s.height, m = min(w, h)
        let flat = FormMetrics(size: s, screen: CGRect(origin: .zero, size: s), radius: 0)
        switch self {
        case .phone:
            let b = max(1.5, m * 0.045), nub = max(1, b * 0.5)
            let body = CGSize(width: w + b * 2, height: h + b * 2)
            return FormMetrics(size: CGSize(width: body.width + nub * 2, height: body.height),
                               screen: CGRect(x: nub + b, y: b, width: w, height: h), radius: max(body.width * 0.16 - b, 1), bezel: b)
        case .foldable(let open):
            // As Apple measures it: open 164.6 × 117.8 mm round a screen of 157.7 × 110.9; closed
            // 84.1 × 117.8 round one of 77.2 × 112.3, the spine side the wider. The buttons stand
            // off the top edge and the right.
            let b = max(1.2, h * (open ? 0.031 : 0.0245)), nub = max(0.7, b * 0.32)
            let spine = open ? b : b * 1.5
            let body = CGSize(width: spine + w + b, height: h + b * 2)
            let radius = open ? body.height * 0.105 : body.width * 0.145
            return FormMetrics(size: CGSize(width: body.width + nub, height: body.height + nub),
                               screen: CGRect(x: spine, y: nub + b, width: w, height: h), radius: max(radius - b, 1), bezel: b)
        case .tablet:
            let b = max(2, m * 0.05)
            let body = CGSize(width: w + b * 2, height: h + b * 2)
            return FormMetrics(size: body, screen: CGRect(x: b, y: b, width: w, height: h),
                               radius: max(min(body.width, body.height) * 0.07 - b, 1), bezel: b)
        case .laptop:
            let b = max(1.2, w * 0.016), chin = b * 1.8
            let lid = CGSize(width: w + b * 2, height: h + b + chin)
            let base = CGSize(width: lid.width * 1.13, height: max(2.5, lid.width * 0.03))
            return FormMetrics(size: CGSize(width: base.width, height: lid.height + base.height),
                               screen: CGRect(x: (base.width - lid.width) / 2 + b, y: b, width: w, height: h), radius: 0.5, bezel: b)
        case .desktop(let iMac):
            let b = max(1.2, w * 0.02), chin = iMac ? h * 0.17 : b
            let head = CGSize(width: w + b * 2, height: b + h + chin)
            let neck = head.height * 0.3, foot = max(1.5, head.height * 0.028)
            return FormMetrics(size: CGSize(width: head.width, height: head.height + neck + foot),
                               screen: CGRect(x: b, y: b, width: w, height: h), radius: 0.5, bezel: b)
        case .browser:
            let bar = max(5, w * 0.045)
            return FormMetrics(size: CGSize(width: w, height: h + bar), screen: CGRect(x: 0, y: bar, width: w, height: h),
                               radius: max(2, w * 0.012), bezel: bar)
        case .watch:
            let b = m * 0.09, band = h * 0.2, crown = b * 0.9
            let body = CGSize(width: w + b * 2, height: h + b * 2)
            return FormMetrics(size: CGSize(width: body.width + crown, height: body.height + band * 2),
                               screen: CGRect(x: b, y: band + b, width: w, height: h), radius: body.width * 0.2, bezel: b)
        case .story: return FormMetrics(size: s, screen: flat.screen, radius: m * 0.04)
        case .banner:
            let d = Self.avatar(s)
            return FormMetrics(size: CGSize(width: w, height: h + d / 2), screen: flat.screen, radius: m * 0.02)
        case .video: return FormMetrics(size: s, screen: flat.screen, radius: m * 0.05)
        case .post(let roundness): return FormMetrics(size: s, screen: flat.screen, radius: m * roundness)
        case .paper, .postcard: return flat
        case .businessCard: return FormMetrics(size: s, screen: flat.screen, radius: m * 0.05)
        case .slide:
            let rod = max(2, h * 0.05), over = w * 0.035, cord = max(5, h * 0.12)
            return FormMetrics(size: CGSize(width: w + over * 2, height: rod * 0.6 + h + cord),
                               screen: CGRect(x: over, y: rod * 0.6, width: w, height: h), radius: 0, bezel: rod)
        case .carousel(let slides):
            return FormMetrics(size: s, screen: flat.screen, radius: min(w / CGFloat(max(slides, 1)), h) * 0.025)
        }
    }

    /// How much larger a point is on it than on the screens round it. The Duo's inner screen has
    /// 430 pixels to the inch against 460 on its outer screen and every other iPhone's, so open it
    /// stands as tall as it does closed, as it does in the hand.
    var density: CGFloat { self == .foldable(open: true) ? 460 / 430 : 1 }

    /// How large a banner's profile picture is.
    static func avatar(_ s: CGSize) -> CGFloat { min(s.height * 0.62, s.width * 0.15) }

    /// The closed Duo's outer screen: square by the spine, round on the side it opens by.
    static func passport(_ m: FormMetrics) -> UnevenRoundedRectangle {
        let small = max(0.5, m.radius * 0.1)
        return UnevenRoundedRectangle(topLeadingRadius: small, bottomLeadingRadius: small,
                                      bottomTrailingRadius: m.radius, topTrailingRadius: m.radius, style: .continuous)
    }

    /// The screen's or the page's outline, for the pencil to go round.
    func outline(_ m: FormMetrics) -> AnyShape {
        switch self {
        case .paper: AnyShape(DogEared(fold: min(m.screen.width, m.screen.height) * 0.13))
        case .foldable(open: false): AnyShape(Self.passport(m))
        default: AnyShape(RoundedRectangle(cornerRadius: m.radius, style: .continuous))
        }
    }
}

struct FormMetrics {
    var size: CGSize
    var screen: CGRect
    var radius: CGFloat
    /// The width of what holds the screen: a device's bezel, a browser's bar, a screen's rod.
    var bezel: CGFloat = 0
}

/// The colours the things are made in: dark glass and graphite, aluminium, the white of an iMac.
private enum Finish {
    static let graphite = Theme.dynamic(0x2F2E2C, 0x4A4844)
    static let graphiteDeep = Theme.dynamic(0x1D1C1B, 0x383633)
    static let silver = Theme.dynamic(0xDCD8D1, 0x7A7670)
    static let silverDeep = Theme.dynamic(0xC0BBB3, 0x605D58)
    static let frontWhite = Theme.dynamic(0xF8F6F2, 0xE4E0D9)
    static let iMacBlue = Theme.dynamic(0xA8BCDF, 0x7387AC)
    static let iMacBlueDeep = Theme.dynamic(0x8EA4CC, 0x60739A)
    static let band = Theme.dynamic(0x55524E, 0x5E5B56)
    static let toolbar = Theme.dynamic(0xEDEAE4, 0xE2DED7)
    static let fold = Theme.dynamic(0xE7E2D9, 0xD5D0C7)
    /// The edge of a device catching the light.
    static let edge = Color.white.opacity(0.2)
    /// Marks printed on a page or shown on a screen: the page is light in either appearance.
    static let mark = Color.black

    /// The Duo's polished titanium, in Star White, and the black glass round its screens.
    static let titanium = Theme.dynamic(0xE6E3DD, 0x8E8A84)
    static let titaniumDeep = Theme.dynamic(0xBAB5AC, 0x67635E)
    static let titaniumRim = Theme.dynamic(0x8F8A81, 0x4F4C48)
    static let glass = Color(red: 0.04, green: 0.04, blue: 0.045)

    static var graphiteBody: LinearGradient { LinearGradient(colors: [graphite, graphiteDeep], startPoint: .top, endPoint: .bottom) }
    static var titaniumBody: LinearGradient { LinearGradient(colors: [titanium, titaniumDeep], startPoint: .top, endPoint: .bottom) }
    static var silverBody: LinearGradient { LinearGradient(colors: [silver, silverDeep], startPoint: .top, endPoint: .bottom) }
}

extension View {
    /// Puts a view at a rectangle of the thing it is part of, measured from its top left.
    fileprivate func place(_ r: CGRect) -> some View {
        frame(width: max(r.width, 0), height: max(r.height, 0)).offset(x: r.minX, y: r.minY)
    }
}

/// A sheet with its top right corner folded over.
private nonisolated struct DogEared: Shape {
    let fold: CGFloat

    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

/// Rolling hills across a whole carousel, rising and falling over the cuts between its slides.
private nonisolated struct Hills: Shape {
    /// The nearer hills, lower and in front.
    var near = false

    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * w, y: r.minY + (near ? y + 0.12 : y) * h) }
        return Path { p in
            p.move(to: at(0, near ? 0.66 : 0.6))
            if near {
                p.addCurve(to: at(0.55, 0.7), control1: at(0.2, 0.52), control2: at(0.36, 0.84))
                p.addCurve(to: at(1, 0.58), control1: at(0.72, 0.58), control2: at(0.86, 0.5))
            } else {
                p.addCurve(to: at(0.3, 0.5), control1: at(0.1, 0.48), control2: at(0.2, 0.42))
                p.addCurve(to: at(0.7, 0.58), control1: at(0.44, 0.6), control2: at(0.56, 0.7))
                p.addCurve(to: at(1, 0.44), control1: at(0.82, 0.48), control2: at(0.92, 0.36))
            }
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

private nonisolated struct Corner: Shape {
    let points: [CGPoint]

    func path(in r: CGRect) -> Path {
        Path { p in
            p.addLines(points.map { CGPoint(x: r.minX + $0.x * r.width, y: r.minY + $0.y * r.height) })
            p.closeSubpath()
        }
    }
}

/// Draws a size's thing round its screen, as small and plain as still tells what it is.
private struct FormDrawing: View {
    let form: SizeForm
    let m: FormMetrics

    var body: some View {
        let s = m.screen, w = s.width, h = s.height, mm = min(w, h)
        ZStack(alignment: .topLeading) {
            switch form {
            case .phone(let island):
                let b = m.bezel, nub = max(1, b * 0.5)
                let body = CGRect(x: nub, y: 0, width: w + b * 2, height: h + b * 2)
                // The buttons along its sides.
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(Finish.graphiteDeep)
                        .place(CGRect(x: 0, y: body.height * [0.17, 0.26, 0.37][i], width: nub * 2, height: body.height * [0.05, 0.09, 0.09][i]))
                }
                Capsule().fill(Finish.graphiteDeep)
                    .place(CGRect(x: body.maxX - nub, y: body.minY + body.height * 0.29, width: nub * 2, height: body.height * 0.14))
                device(RoundedRectangle(cornerRadius: body.width * 0.16, style: .continuous), body)
                screen(RoundedRectangle(cornerRadius: m.radius, style: .continuous))
                if island {
                    Capsule().fill(Color.black)
                        .place(CGRect(x: s.midX - w * 0.15, y: s.minY + max(1.2, w * 0.035), width: w * 0.3, height: max(1.5, w * 0.085)))
                } else {
                    let d = max(1.5, w * 0.05)
                    Circle().fill(Color.black)
                        .place(CGRect(x: s.midX - d / 2, y: s.minY + max(1.2, w * 0.04), width: d, height: d))
                }

            case .foldable(let open):
                let b = m.bezel, nub = s.minY - b
                let body = CGRect(x: 0, y: nub, width: m.size.width - nub, height: m.size.height - nub)
                let frame = max(0.5, b * 0.38)
                let side: (from: CGFloat, length: CGFloat) = open ? (0.275, 0.155) : (0.29, 0.15)
                let volume: [CGFloat] = open ? [0.728, 0.806] : [0.46, 0.62]
                // Volume along the top, over the half the side button is on, which has Touch ID.
                ForEach(0..<2, id: \.self) { i in
                    Capsule().fill(Finish.titaniumDeep)
                        .place(CGRect(x: body.width * volume[i], y: 0,
                                      width: body.width * (open ? 0.064 : 0.12), height: nub * 2.4))
                }
                Capsule().fill(Finish.titaniumDeep)
                    .place(CGRect(x: body.maxX - nub * 1.4, y: body.minY + body.height * side.from, width: nub * 2.4, height: body.height * side.length))
                if open {
                    let r = m.radius + b
                    titanium(RoundedRectangle(cornerRadius: r, style: .continuous), body)
                    RoundedRectangle(cornerRadius: r - frame, style: .continuous).fill(Finish.glass)
                        .place(body.insetBy(dx: frame, dy: frame))
                    screen(RoundedRectangle(cornerRadius: m.radius, style: .continuous))
                    // The fold down the middle: a seam in the frame above and below, and on the
                    // screen only a faint line where it catches the light.
                    ForEach(0..<2, id: \.self) { i in
                        Rectangle().fill(Finish.titaniumDeep)
                            .place(CGRect(x: body.midX - 0.35, y: i == 0 ? body.minY : body.maxY - frame, width: 0.7, height: frame))
                    }
                    LinearGradient(colors: [Finish.mark.opacity(0), Finish.mark.opacity(0.07), Color.white.opacity(0.5), Finish.mark.opacity(0.07), Finish.mark.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .place(CGRect(x: s.midX - max(1.5, w * 0.014), y: s.minY, width: max(3, w * 0.028), height: h))
                } else {
                    let r = m.radius + b, small = max(0.6, body.width * 0.022)
                    let shape = UnevenRoundedRectangle(topLeadingRadius: small, bottomLeadingRadius: small,
                                                       bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous)
                    titanium(shape, body)
                    // The hinge's rail down the spine.
                    Rectangle().fill(Finish.titaniumDeep)
                        .place(CGRect(x: s.minX * 0.42, y: body.minY + small, width: max(0.5, s.minX * 0.1), height: body.height - small * 2))
                    UnevenRoundedRectangle(topLeadingRadius: small * 0.5, bottomLeadingRadius: small * 0.5,
                                           bottomTrailingRadius: r - frame, topTrailingRadius: r - frame, style: .continuous)
                        .fill(Finish.glass)
                        .place(CGRect(x: s.minX * 0.62, y: body.minY + frame, width: body.maxX - frame - s.minX * 0.62, height: body.height - frame * 2))
                    screen(SizeForm.passport(m))
                    // The front camera, in the corner over the side button.
                    let d = max(1.2, w * 0.076)
                    Circle().fill(Color.black)
                        .place(CGRect(x: s.minX + w * 0.89 - d / 2, y: s.minY + h * 0.077 - d / 2, width: d, height: d))
                }

            case .tablet:
                let b = m.bezel
                let body = CGRect(x: 0, y: 0, width: w + b * 2, height: h + b * 2)
                device(RoundedRectangle(cornerRadius: min(body.width, body.height) * 0.07, style: .continuous), body)
                screen(RoundedRectangle(cornerRadius: m.radius, style: .continuous))
                let d = max(1, b * 0.35)
                Circle().fill(Color.black.opacity(0.6))
                    .place(CGRect(x: body.midX - d / 2, y: b / 2 - d / 2, width: d, height: d))

            case .laptop:
                let b = m.bezel
                let lid = CGRect(x: s.minX - b, y: 0, width: w + b * 2, height: h + b * 2.8)
                let base = CGRect(x: 0, y: lid.maxY, width: m.size.width, height: m.size.height - lid.maxY)
                device(UnevenRoundedRectangle(topLeadingRadius: lid.width * 0.03, bottomLeadingRadius: 0.5,
                                              bottomTrailingRadius: 0.5, topTrailingRadius: lid.width * 0.03, style: .continuous), lid)
                screen(Rectangle())
                // The notch.
                let nw = w * 0.09, nh = max(1, b * 1.1)
                UnevenRoundedRectangle(bottomLeadingRadius: nh * 0.4, bottomTrailingRadius: nh * 0.4)
                    .fill(Finish.graphite)
                    .place(CGRect(x: s.midX - nw / 2, y: s.minY, width: nw, height: nh))
                UnevenRoundedRectangle(topLeadingRadius: 0.5, bottomLeadingRadius: base.height * 0.7,
                                       bottomTrailingRadius: base.height * 0.7, topTrailingRadius: 0.5)
                    .fill(Finish.silverBody)
                    .overlay(alignment: .top) { Rectangle().fill(Finish.edge).frame(height: 0.5) }
                    .place(base)
                // Where a thumb opens it.
                let gw = lid.width * 0.15, gh = max(0.6, base.height * 0.32)
                UnevenRoundedRectangle(bottomLeadingRadius: gh * 0.8, bottomTrailingRadius: gh * 0.8)
                    .fill(Finish.silverDeep)
                    .place(CGRect(x: base.midX - gw / 2, y: base.minY, width: gw, height: gh))

            case .desktop(let iMac):
                let b = m.bezel
                let head = CGRect(x: 0, y: 0, width: m.size.width, height: b + h + (iMac ? h * 0.17 : b))
                let neckHeight = head.height * 0.3, foot = m.size.height - head.height - neckHeight
                let neck = CGRect(x: head.midX - head.width * 0.1, y: head.maxY - 1, width: head.width * 0.2, height: neckHeight + 1)
                Rectangle()
                    .fill(LinearGradient(colors: iMac ? [Finish.iMacBlueDeep, Finish.iMacBlue] : [Finish.silverDeep, Finish.silver],
                                         startPoint: .top, endPoint: .bottom))
                    .place(neck)
                Capsule()
                    .fill(iMac ? Finish.iMacBlueDeep : Finish.silverDeep)
                    .place(CGRect(x: head.midX - head.width * 0.15, y: neck.maxY - 0.5, width: head.width * 0.3, height: foot + 0.5))
                if iMac {
                    RoundedRectangle(cornerRadius: head.width * 0.022, style: .continuous)
                        .fill(LinearGradient(colors: [Finish.iMacBlue, Finish.iMacBlueDeep], startPoint: .top, endPoint: .bottom))
                        .place(head)
                    UnevenRoundedRectangle(topLeadingRadius: head.width * 0.022, topTrailingRadius: head.width * 0.022, style: .continuous)
                        .fill(Finish.frontWhite)
                        .overlay { UnevenRoundedRectangle(topLeadingRadius: head.width * 0.022, topTrailingRadius: head.width * 0.022, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5) }
                        .place(CGRect(x: 0, y: 0, width: head.width, height: h + b * 2))
                } else {
                    device(RoundedRectangle(cornerRadius: head.width * 0.016, style: .continuous), head)
                }
                screen(Rectangle())

            case .browser:
                let bar = m.bezel, r = m.radius
                let window = CGRect(origin: .zero, size: m.size)
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .fill(Paper.stock)
                    .place(window)
                UnevenRoundedRectangle(topLeadingRadius: r, topTrailingRadius: r, style: .continuous)
                    .fill(Finish.toolbar)
                    .place(CGRect(x: 0, y: 0, width: w, height: bar))
                Rectangle().fill(Finish.mark.opacity(0.08))
                    .place(CGRect(x: 0, y: bar - 0.5, width: w, height: 0.5))
                let d = bar * 0.26
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.78, blue: 0.25)][i])
                        .place(CGRect(x: bar * 0.4 + CGFloat(i) * d * 1.7, y: bar / 2 - d / 2, width: d, height: d))
                }
                Capsule().fill(Finish.mark.opacity(0.07))
                    .place(CGRect(x: w * 0.33, y: bar * 0.28, width: w * 0.34, height: bar * 0.44))
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .strokeBorder(Finish.mark.opacity(0.12), lineWidth: 0.5)
                    .place(window)

            case .watch:
                let b = m.bezel, band = h * 0.2
                let body = CGRect(x: 0, y: band, width: w + b * 2, height: h + b * 2)
                let bw = body.width * 0.72
                // The band, running off above and below.
                UnevenRoundedRectangle(topLeadingRadius: bw * 0.12, topTrailingRadius: bw * 0.12)
                    .fill(LinearGradient(colors: [Finish.band.opacity(0), Finish.band], startPoint: .top, endPoint: .bottom))
                    .place(CGRect(x: body.midX - bw / 2, y: 0, width: bw, height: band + b))
                UnevenRoundedRectangle(bottomLeadingRadius: bw * 0.12, bottomTrailingRadius: bw * 0.12)
                    .fill(LinearGradient(colors: [Finish.band, Finish.band.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .place(CGRect(x: body.midX - bw / 2, y: body.maxY - b, width: bw, height: band + b))
                let crown = m.size.width - body.width
                RoundedRectangle(cornerRadius: crown * 0.35).fill(Finish.silverBody)
                    .place(CGRect(x: body.maxX - crown * 0.6, y: body.minY + body.height * 0.22, width: crown * 1.6, height: body.height * 0.17))
                Capsule().fill(Finish.graphiteDeep)
                    .place(CGRect(x: body.maxX - crown * 0.5, y: body.minY + body.height * 0.5, width: crown, height: body.height * 0.22))
                device(RoundedRectangle(cornerRadius: body.width * 0.28, style: .continuous), body)
                screen(RoundedRectangle(cornerRadius: m.radius, style: .continuous))

            case .story(let sideButtons):
                screen(RoundedRectangle(cornerRadius: m.radius, style: .continuous))
                let inset = w * 0.06, d = w * 0.1
                if sideButtons {
                    ForEach(0..<3, id: \.self) { i in
                        Circle().fill(Finish.mark.opacity(0.13))
                            .place(CGRect(x: w * 0.84 - d / 2, y: h * (0.5 + CGFloat(i) * 0.08), width: d, height: d))
                    }
                    Capsule().fill(Finish.mark.opacity(0.12)).place(CGRect(x: inset, y: h * 0.85, width: w * 0.5, height: max(1, h * 0.013)))
                    Capsule().fill(Finish.mark.opacity(0.09)).place(CGRect(x: inset, y: h * 0.885, width: w * 0.32, height: max(1, h * 0.013)))
                } else {
                    let gap = max(1, w * 0.02), bar = (w - inset * 2 - gap * 2) / 3
                    ForEach(0..<3, id: \.self) { i in
                        Capsule().fill(Finish.mark.opacity(i == 0 ? 0.32 : 0.13))
                            .place(CGRect(x: inset + CGFloat(i) * (bar + gap), y: h * 0.025, width: bar, height: max(1, h * 0.008)))
                    }
                    Circle().fill(Finish.mark.opacity(0.12))
                        .place(CGRect(x: inset, y: h * 0.05, width: d, height: d))
                    Capsule().fill(Finish.mark.opacity(0.1))
                        .place(CGRect(x: inset + d * 1.3, y: h * 0.05 + d * 0.35, width: w * 0.26, height: d * 0.3))
                }

            case .banner:
                screen(RoundedRectangle(cornerRadius: m.radius, style: .continuous))
                let d = SizeForm.avatar(s.size)
                Circle()
                    .fill(Paper.stock)
                    .overlay { Circle().fill(Finish.mark.opacity(0.1)).padding(d * 0.12) }
                    .overlay { Circle().strokeBorder(Color(nsColor: CanvasInk.table), lineWidth: max(1, d * 0.07)) }
                    .place(CGRect(x: w * 0.05, y: h - d / 2, width: d, height: d))

            case .video:
                screen(RoundedRectangle(cornerRadius: m.radius, style: .continuous))
                let pw = w * 0.12, ph = h * 0.085
                RoundedRectangle(cornerRadius: ph * 0.25).fill(Color.black.opacity(0.62))
                    .place(CGRect(x: w - pw - w * 0.03, y: h - ph - h * 0.045, width: pw, height: ph))

            case .post:
                screen(RoundedRectangle(cornerRadius: m.radius, style: .continuous))

            case .paper:
                let fold = mm * 0.13
                screen(DogEared(fold: fold))
                Corner(points: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)])
                    .fill(Finish.fold)
                    .shadow(color: Color.black.opacity(0.14), radius: 1, x: -0.5, y: 0.5)
                    .place(CGRect(x: w - fold, y: 0, width: fold, height: fold))

            case .businessCard:
                // Another card under it, from the same box.
                RoundedRectangle(cornerRadius: m.radius, style: .continuous)
                    .fill(Finish.fold)
                    .rotationEffect(.degrees(-8))
                    .offset(x: w * 0.07, y: -h * 0.04)
                    .place(s)
                screen(RoundedRectangle(cornerRadius: m.radius, style: .continuous))
                let d = h * 0.2
                Circle().fill(Theme.pencil.opacity(0.35))
                    .place(CGRect(x: w * 0.1, y: h * 0.16, width: d, height: d))
                Capsule().fill(Finish.mark.opacity(0.14)).place(CGRect(x: w * 0.1, y: h * 0.66, width: w * 0.42, height: max(1, h * 0.05)))
                Capsule().fill(Finish.mark.opacity(0.09)).place(CGRect(x: w * 0.1, y: h * 0.77, width: w * 0.28, height: max(1, h * 0.04)))

            case .postcard:
                screen(Rectangle())
                let sw = w * 0.17
                Rectangle()
                    .fill(Theme.pencil.opacity(0.16))
                    .overlay { Rectangle().strokeBorder(Finish.mark.opacity(0.22), style: StrokeStyle(lineWidth: 0.6, dash: [1, 1])) }
                    .place(CGRect(x: w - sw - w * 0.07, y: w * 0.07, width: sw, height: sw * 1.2))
                Rectangle().fill(Finish.mark.opacity(0.08))
                    .place(CGRect(x: w * 0.5, y: h * 0.12, width: 0.6, height: h * 0.76))
                ForEach(0..<3, id: \.self) { i in
                    Rectangle().fill(Finish.mark.opacity(0.1))
                        .place(CGRect(x: w * 0.57, y: h * (0.5 + CGFloat(i) * 0.1), width: w * 0.34, height: 0.6))
                }

            case .slide:
                let rod = m.bezel
                screen(Rectangle())
                Capsule().fill(Finish.mark.opacity(0.15)).place(CGRect(x: s.minX + w * 0.08, y: s.minY + h * 0.14, width: w * 0.42, height: h * 0.05))
                Capsule().fill(Finish.mark.opacity(0.08)).place(CGRect(x: s.minX + w * 0.08, y: s.minY + h * 0.23, width: w * 0.27, height: h * 0.035))
                // The screen's rod, and the cord that pulls it down.
                Capsule().fill(Finish.graphiteBody)
                    .overlay(alignment: .top) { Capsule().fill(Finish.edge).frame(height: 0.5) }
                    .place(CGRect(x: 0, y: 0, width: m.size.width, height: rod))
                let cord = m.size.height - s.maxY, knob = max(2, cord * 0.36)
                Rectangle().fill(Finish.graphite.opacity(0.7))
                    .place(CGRect(x: s.midX - 0.4, y: s.maxY, width: 0.8, height: cord - knob))
                Capsule().fill(Finish.graphite)
                    .place(CGRect(x: s.midX - knob * 0.4, y: m.size.height - knob, width: knob * 0.8, height: knob))

            case .carousel(let slides):
                // One picture across every slide, as a carousel is designed, cut where the slides
                // meet: hills running on from one into the next, a sun on the first cut.
                let gap = max(1, w * 0.008), slide = (w - gap * CGFloat(slides - 1)) / CGFloat(slides)
                let sun = h * 0.3
                // The cuts, a crease's shade between the slides rather than the table under them.
                RoundedRectangle(cornerRadius: m.radius, style: .continuous)
                    .fill(Finish.fold)
                    .place(s.insetBy(dx: m.radius, dy: 0))
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Paper.stock)
                    Circle().fill(Theme.pencil.opacity(0.22))
                        .place(CGRect(x: slide + gap / 2 - sun / 2, y: h * 0.2, width: sun, height: sun))
                    Hills().fill(Theme.pencil.opacity(0.13))
                    Hills(near: true).fill(Theme.pencil.opacity(0.2))
                    Capsule().fill(Finish.mark.opacity(0.18))
                        .place(CGRect(x: slide * 0.1, y: h * 0.1, width: slide * 0.46, height: max(1, h * 0.04)))
                    Capsule().fill(Finish.mark.opacity(0.1))
                        .place(CGRect(x: slide * 0.1, y: h * 0.1 + max(2, h * 0.07), width: slide * 0.3, height: max(1, h * 0.03)))
                }
                .frame(width: w, height: h)
                .mask {
                    HStack(spacing: gap) {
                        ForEach(0..<slides, id: \.self) { _ in RoundedRectangle(cornerRadius: m.radius, style: .continuous) }
                    }
                }
                .place(s)
            }
        }
        .frame(width: m.size.width, height: m.size.height, alignment: .topLeading)
    }

    /// A device's body in graphite, its edge catching the light.
    private func device<S: Shape>(_ shape: S, _ r: CGRect) -> some View {
        shape.fill(Finish.graphiteBody)
            .overlay { shape.stroke(Finish.edge, lineWidth: 0.6) }
            .place(r)
    }

    /// The Duo's body in polished titanium: a darker rim where it turns away, a bright line inside
    /// it where it catches the light.
    private func titanium<S: InsettableShape>(_ shape: S, _ r: CGRect) -> some View {
        shape.fill(Finish.titaniumBody)
            .overlay { shape.strokeBorder(Finish.titaniumRim, lineWidth: 0.6) }
            .overlay { shape.inset(by: 0.6).strokeBorder(Color.white.opacity(0.6), lineWidth: 0.5) }
            .place(r)
    }

    /// The screen, or the page: white, as an artboard is.
    private func screen<S: Shape>(_ shape: S) -> some View {
        shape.fill(Paper.stock).place(m.screen)
    }
}

// MARK: A size of your own

/// One sheet of your own on the table, standing in the middle at a scale that leaves it room to
/// grow. Its corner pulls it to any size, whole tens at a time; the width and height can be typed
/// under it. A click on it, or Return in either number, starts a design that size.
private struct OwnSizeStage: View {
    @Binding var width: Double
    @Binding var height: Double
    let light: Daylight
    let start: () -> Void
    @State private var pulled: CGSize?
    /// The scale held while the corner is pulled, so the sheet stays under the pointer.
    @State private var held: CGFloat?
    @State private var hovering = false
    @State private var shown = false

    static let room = CGSize(width: 620, height: Lineup.tallest)
    /// How much of the room the sheet takes at rest, leaving the rest to pull it into.
    static let rest: CGFloat = 0.78

    private var chosen: CGSize { CGSize(width: max(width.rounded(), 1), height: max(height.rounded(), 1)) }

    var body: some View {
        let size = pulled ?? chosen
        let s = held ?? min(Self.room.width / chosen.width, Self.room.height / chosen.height) * Self.rest
        let w = max((size.width * s).rounded(), 6), h = max((size.height * s).rounded(), 6)
        let lifted = hovering && pulled == nil
        VStack(spacing: 14) {
            ZStack(alignment: .bottom) {
                Ellipse()
                    .fill(CanvasShadow.color.opacity(lifted ? 0.14 : 0.3))
                    .frame(width: w * (lifted ? 0.96 : 0.86), height: min(max(w * 0.06, 4), 9))
                    .blur(radius: lifted ? 6 : 2.5)
                    .offset(x: light.lean, y: 3)
                ZStack(alignment: .topTrailing) {
                    Button(action: start) {
                        Rectangle()
                            .fill(Paper.stock)
                            .overlay {
                                Rectangle().strokeBorder(Theme.pencil, lineWidth: 1.5).opacity(lifted || pulled != nil ? 1 : 0)
                            }
                            .overlay {
                                Circle()
                                    .fill(Theme.pencil)
                                    .overlay {
                                        Image(systemName: "plus")
                                            .font(.system(size: 10.5, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                    .frame(width: 22, height: 22)
                                    .opacity(lifted && w >= 30 && h >= 30 ? 1 : 0)
                                    .scaleEffect(lifted ? 1 : 0.4)
                            }
                            .compositingGroup()
                            .shadow(color: CanvasShadow.color.opacity(lifted ? 0.3 : 0.14), radius: lifted ? 14 : 3,
                                    x: light.lean * (lifted ? 1.2 : 0.4), y: lifted ? 12 : 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(Pressable())
                    .onHover { hovering = $0 }
                    handle(scale: s)
                        .offset(x: 5, y: -5)
                }
                .frame(width: w, height: h)
                .offset(y: lifted ? -9 : 0)
            }
            .frame(width: Self.room.width, height: Self.room.height, alignment: .bottom)
            .coordinateSpace(name: "own")
            .help("Start a design \(Int(size.width)) by \(Int(size.height))")
            VStack(spacing: 3) {
                Text("Your own size")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(lifted ? Theme.pencil : Theme.ink)
                HStack(spacing: 4) {
                    if let pulled {
                        Text(verbatim: "\(Int(pulled.width)) × \(Int(pulled.height))")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.pencil)
                            .contentTransition(.numericText())
                    } else {
                        PlainNumber(value: $width, submit: start)
                        Text(verbatim: "×")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ink3)
                        PlainNumber(value: $height, submit: start)
                    }
                }
                .frame(height: 17)
            }
        }
        .padding(.top, Lineup.above)
        .padding(.bottom, Lineup.below)
        .frame(maxWidth: .infinity)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 14)
        .animation(pulled == nil ? .spring(response: 0.42, dampingFraction: 0.74) : .interactiveSpring(response: 0.16, dampingFraction: 0.86), value: size)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: held)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: lifted)
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.72).delay(0.04)) { shown = true } }
    }

    /// The canvas's handle on the sheet's top right corner. The sheet grows from the middle of
    /// its foot, so the corner pulled out stretches it both ways at once.
    private func handle(scale s: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(.white)
            .overlay { RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Theme.pencil, lineWidth: 1) }
            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
            .frame(width: pulled != nil ? 12 : 10, height: pulled != nil ? 12 : 10)
            .frame(width: 10, height: 10)
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("own"))
                    .onChanged { value in
                        if held == nil { held = s }
                        pulled = corner(at: value.location, scale: held ?? s)
                    }
                    .onEnded { value in
                        let size = corner(at: value.location, scale: held ?? s)
                        width = size.width
                        height = size.height
                        pulled = nil
                        held = nil
                    }
            )
            .pointerStyle(.frameResize(position: .topTrailing))
            .help("Drag the corner for a size of your own")
    }

    /// The size the corner makes at a point: twice as wide as it is from the middle, as tall as
    /// it is above the table, in whole tens (or ones, close up), and no larger than the room.
    private func corner(at p: CGPoint, scale s: CGFloat) -> CGSize {
        let step: CGFloat = s < 0.5 ? 10 : 1
        let w = abs(p.x - Self.room.width / 2) * 2 / s, h = (Self.room.height - p.y) / s
        return CGSize(width: min(max((w / step).rounded() * step, 10), Self.room.width / s),
                      height: min(max((h / step).rounded() * step, 10), (Self.room.height + Lineup.above - 6) / s))
    }
}

/// The white of a sheet of paper on the table, as an artboard is on the canvas.
enum Paper {
    static let stock = Theme.dynamic(0xFFFFFF, 0xF4F1EB)
}

/// The soft shadow artboards cast on the table.
enum CanvasShadow {
    static let color = Color(nsColor: CanvasInk.shadow)
}

/// A bare number for your own size, in a faint well that shows it can be typed into.
private struct PlainNumber: View {
    @Binding var value: Double
    /// Return starts the design.
    var submit: (() -> Void)?
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Theme.ink2)
            .multilineTextAlignment(.center)
            .focused($focused)
            .frame(width: 46, height: 17)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.ink.opacity(focused ? 0.12 : 0.07))
            }
            .onAppear { draft = String(Int(value)) }
            .onSubmit {
                commit()
                submit?()
            }
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onChange(of: draft) { _, typed in
                // The sheet takes the new shape as it is typed.
                if let v = Double(typed), v >= 1, v <= 100_000 { value = v }
            }
            .onChange(of: value) { _, now in if !focused { draft = String(Int(now)) } }
    }

    private func commit() {
        if let v = Double(draft), v >= 1, v <= 100_000 { value = v }
        draft = String(Int(value))
    }
}
