import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The first thing you see: a greeting asking what is to be designed, every size named under it,
/// and beside them a sheet of paper that takes the shape of each, to start a design on; then your
/// designs, latest first.
struct HomeView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var library = Library.shared
    @State private var menus = MenuHost()
    @State private var dropping = false
    /// What your designs are being looked through for.
    @State private var search = ""
    /// How wide the column of words down the left is, beside the tables on the right.
    static let column: CGFloat = 286
    /// Turns true as the screen first shows, so its parts can rise into place one after another.
    @State private var appeared = false
    /// Where the bar along the top has its name: after the window's buttons.
    static let nameLeading: CGFloat = 92
    /// How far in from the window's edges the page keeps, on the left in line with the window's
    /// buttons, and on the right with Open.
    static let edge: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: "Bezzle")
                    .font(Theme.serif(15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                CardButton(title: "Open…", height: 28) { openPanel() }
                    .help("Open a design, or an XD, Figma or Sketch file  ⌘O")
            }
            .padding(.leading, Self.nameLeading)
            .padding(.trailing, Self.edge)
            .frame(height: Theme.barHeight)
            // Above the designs below: their scroll view reaches up under the title bar, and
            // would otherwise take the clicks meant for Open.
            .zIndex(1)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    StartArea(appeared: appeared) { size, name in create(size, name: name) }
                        .padding(.bottom, 56)
                    recents
                }
                .padding(.horizontal, Self.edge)
                .padding(.top, 22)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .edgeFade()
            #if DEBUG
            // BEZZLE_HOME_END=1 opens it at the bottom, to see your designs in a test run's snapshot.
            .defaultScrollAnchor(ProcessInfo.processInfo.environment["BEZZLE_HOME_END"] != nil ? .bottom : .top)
            #endif
        }
        .background(Theme.paper)
        .ignoresSafeArea()
        .frame(minWidth: 760, minHeight: 520)
        .overlay {
            if dropping {
                DropTarget()
                    .transition(.opacity)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let designs = urls.filter { BezzleDocument.fileExtensions.contains($0.pathExtension.lowercased()) || Importer.imports($0) }
            designs.forEach(open)
            return !designs.isEmpty
        } isTargeted: { over in withAnimation(Theme.spring) { dropping = over } }
        .overlayPreferenceValue(MenuAnchorKey.self) { MenuLayer(anchors: $0) }
        .environment(menus)
        .onAppear {
            library.refresh()
            WindowRouter.shared.openWindow = openWindow
            WindowRouter.shared.dismissWindow = dismissWindow
            WindowRouter.shared.flush()
            appeared = true
            library.homeShowing = true
        }
        .onDisappear { library.homeShowing = false }
    }

    // MARK: Starting something

    static func greeting(at date: Date) -> LocalizedStringResource {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning."
        case 12..<18: "Good afternoon."
        default: "Good evening."
        }
    }

    private func create(_ size: CGSize, name: String) {
        guard let url = library.create(artboard: size, name: name) else { return }
        open(url)
    }

    private func open(_ url: URL) {
        WindowRouter.shared.open(url)
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DesignFile.openableTypes
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Open")
        if panel.runModal() == .OK { panel.urls.forEach(open) }
    }

    // MARK: Your designs

    /// Your designs, laid out as the top of the screen is: their name and where to find them in
    /// the column of words on the left, and the designs themselves on the right, in the room the
    /// size table takes above them.
    private var recents: some View {
        let sync = CloudSync.shared
        let arriving = sync.arriving.sorted { $0.value.title < $1.value.title }.map(\.value)
        let query = search.trimmingCharacters(in: .whitespaces)
        let entries = query.isEmpty ? library.entries : library.entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text("Your designs")
                        .font(Theme.serif(26, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    if !library.entries.isEmpty {
                        Text(verbatim: library.entries.count.formatted())
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Theme.ink3)
                    }
                }
                .padding(.bottom, 16)
                if library.entries.count > 6 {
                    SearchWell(text: $search)
                        .padding(.bottom, 12)
                }
                TextButton(title: "Show in Finder") { NSWorkspace.shared.open(library.folder) }
                    .padding(.leading, -8)
            }
            .frame(width: Self.column, alignment: .topLeading)
            .rising(appeared, order: 12)
            Group {
                if library.entries.isEmpty && arriving.isEmpty && sync.invitationProblem == nil {
                    NoDesigns()
                        .rising(appeared, order: 13)
                } else if entries.isEmpty && arriving.isEmpty {
                    Text("No design with that name")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink3)
                        .padding(.top, 10)
                } else {
                    DesignGrid(entries: entries, arriving: arriving, problem: sync.invitationProblem,
                               dismissProblem: { sync.invitationProblem = nil }, featured: query.isEmpty, appeared: appeared) { open($0) }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
            .animation(Theme.spring, value: sync.arriving)
            .animation(Theme.spring, value: sync.invitationProblem)
            .animation(Theme.spring, value: entries.map(\.url))
        }
    }
}

extension View {
    /// Rises into place as the home screen first shows, after the parts before it.
    fileprivate func rising(_ shown: Bool, order: Int) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .animation(Theme.spring.delay(0.04 + Double(order) * 0.035), value: shown)
    }
}

// MARK: - Starting a design

/// The top of the home screen. On the left the greeting, asking what is to be designed, and under
/// it every family of sizes by name: makers' devices, platforms' formats, paper and slides; the
/// open family's sizes are listed under them. On the right a table with one sheet of paper on it,
/// the size chosen, over the pencil outlines of the open family's other sizes, laid from the same
/// corner at one scale as a size chart is, and as large as the table lets them be. Opening a
/// family, the table comes in close or stands back to fit it and the sheet takes its first size;
/// pointing at a size, the sheet takes its shape; its corner pulls it to any size, catching on the
/// others' widths and heights as it passes; and a click on it, or on a size, starts a design that
/// size. The size chosen last is the one the sheet comes back to.
private struct StartArea: View {
    let appeared: Bool
    let create: (CGSize, String) -> Void
    @AppStorage("home.width", store: Library.settings) private var width: Double = Preset.standard.size.width
    @AppStorage("home.height", store: Library.settings) private var height: Double = Preset.standard.size.height
    /// The size chosen, by name, telling apart two of the same size; empty for one's own.
    @AppStorage("home.preset", store: Library.settings) private var chosenName = Preset.standard.name
    @AppStorage("home.family", store: Library.settings) private var openName = Preset.standard.group.rawValue
    /// The size pointed at in the list, which the sheet takes on meanwhile.
    @State private var pointed: Preset?
    /// Where the sheet's corner is being pulled to.
    @State private var pulled: CGSize?
    @Namespace private var families

    /// The list of sizes has room for the longest family's, so opening another moves nothing.
    static let rows = Preset.Group.allCases.map { Preset.all(in: $0).count }.max() ?? 0

    private var open: Preset.Group { Preset.Group(rawValue: openName) ?? Preset.standard.group }
    private var chosen: CGSize { CGSize(width: width.rounded(), height: height.rounded()) }
    private var shown: CGSize { pulled ?? pointed?.size ?? chosen }

    /// What the sheet is: the size pointed at, the one chosen, or one of one's own.
    private var shownPreset: Preset? {
        if pulled != nil { return Preset.all(in: open).first { $0.size == shown } }
        if let pointed { return pointed }
        return Preset.all.first { $0.name == chosenName && $0.size == chosen } ?? Preset.all(in: open).first { $0.size == chosen }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 0) {
                greeting
                    .rising(appeared, order: 0)
                    .padding(.bottom, 24)
                index
                    .rising(appeared, order: 1)
                    .padding(.bottom, 16)
                Hairline()
                    .padding(.bottom, 8)
                sizes
                    .rising(appeared, order: 2)
            }
            .frame(width: HomeView.column, alignment: .topLeading)
            SizeChart(group: open, shown: shown, shownPreset: shownPreset, pointed: pointed, pulling: pulled != nil,
                      chosen: chosen, width: $width, height: $height, appeared: appeared,
                      pull: { size in
                          pulled = size
                          if size == nil { chosenName = Preset.all(in: open).first { $0.size == chosen }?.name ?? "" }
                      },
                      start: { start(shown, preset: shownPreset) })
                .frame(minHeight: 420, maxHeight: .infinity)
                .rising(appeared, order: 3)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Theme.ink3)
            VStack(alignment: .leading, spacing: 2) {
                Text(HomeView.greeting(at: .now))
                    .foregroundStyle(Theme.ink)
                Text("What are you designing today?")
                    .foregroundStyle(Theme.ink3)
            }
            .font(Theme.serif(30, weight: .medium))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Every family by name, run on like words in a paragraph under what kind of size they are;
    /// the open one underlined in pencil, the line moving across as another opens.
    private var index: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Preset.Kind.allCases, id: \.self) { kind in
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(1.1)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.ink3)
                    Flow(spacing: 15, lineSpacing: 1) {
                        ForEach(Preset.Group.all(of: kind), id: \.self) { group in
                            FamilyName(group: group, open: group == open, underline: families) { choose(group) }
                        }
                    }
                }
            }
        }
    }

    /// The open family's sizes, each to point at and to start with.
    private var sizes: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Preset.all(in: open)) { preset in
                    SizeRow(preset: preset, chosen: pointed == nil && pulled == nil && shownPreset == preset,
                            point: { on in
                                if on { pointed = preset } else if pointed == preset { pointed = nil }
                            },
                            start: { start(preset.size, preset: preset) })
                }
            }
            .id(open)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
        }
        .frame(height: CGFloat(Self.rows) * SizeRow.height, alignment: .top)
        .padding(.leading, -10)
    }

    /// Opens a family, and lays its first size on the table.
    private func choose(_ group: Preset.Group) {
        guard group != open, let first = Preset.all(in: group).first else { return }
        pointed = nil
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
            openName = group.rawValue
            width = first.size.width
            height = first.size.height
            chosenName = first.name
        }
    }

    private func start(_ size: CGSize, preset: Preset?) {
        width = size.width
        height = size.height
        chosenName = preset?.name ?? ""
        create(size, preset.map { String(localized: $0.title) } ?? String(localized: "Artboard"))
    }
}

/// A family's name in the index, which opens it: in ink while open, underlined in pencil.
private struct FamilyName: View {
    let group: Preset.Group
    let open: Bool
    let underline: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(group.title)
                .font(Theme.serif(16, weight: open ? .semibold : .medium))
                .foregroundStyle(open || hovering ? Theme.ink : Theme.ink3)
                .lineLimit(1)
                .fixedSize()
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) {
                    if open {
                        Capsule()
                            .fill(Theme.pencil)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "open", in: underline)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
    }
}

/// Lays its views out in lines, as words are: each line as full as it can be before the next.
private struct Flow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width ?? .infinity)
        let width = lines.map { $0.width }.max() ?? 0
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in line.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = [Line()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let needed = lines[lines.count - 1].items.isEmpty ? size.width : lines[lines.count - 1].width + spacing + size.width
            if needed > width && !lines[lines.count - 1].items.isEmpty {
                lines.append(Line(items: [i], width: size.width, height: size.height))
            } else {
                lines[lines.count - 1].items.append(i)
                lines[lines.count - 1].width = needed
                lines[lines.count - 1].height = max(lines[lines.count - 1].height, size.height)
            }
        }
        return lines
    }
}

/// A size in the list: its name, and its width and height set small after it. Pointed at, it
/// takes the pencil's blue and shows the way in.
private struct SizeRow: View {
    let preset: Preset
    /// Whether the sheet is this size.
    let chosen: Bool
    let point: (Bool) -> Void
    let start: () -> Void
    @State private var hovering = false

    static let height: CGFloat = 28

    var body: some View {
        Button(action: start) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.pencil)
                    .frame(width: 5, height: 5)
                    .opacity(chosen ? 1 : 0)
                    .scaleEffect(chosen ? 1 : 0.3)
                Text(preset.title)
                    .font(.system(size: 13, weight: hovering || chosen ? .semibold : .regular))
                    .foregroundStyle(hovering || chosen ? Theme.pencil : Theme.ink)
                Spacer(minLength: 8)
                Text(verbatim: "\(Int(preset.size.width)) × \(Int(preset.size.height))")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(hovering ? Theme.pencil.opacity(0.8) : Theme.ink3)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.pencil)
                    .opacity(hovering ? 1 : 0)
                    .offset(x: hovering ? 0 : -5)
                    .frame(width: 12)
            }
            .lineLimit(1)
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .frame(height: Self.height)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Theme.pencilWash : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { on in
            hovering = on
            point(on)
        }
        .animation(Theme.quick, value: hovering)
        .animation(Theme.spring, value: chosen)
        .help("Start a design \(Int(preset.size.width)) by \(Int(preset.size.height))")
        .accessibilityLabel("\(String(localized: preset.title)), \(Int(preset.size.width)) by \(Int(preset.size.height))")
    }
}

/// The table with the sheet on it, over the outlines of the open kind's sizes from one corner at
/// one scale, all of it in the middle of the table. Each outline is sketched in as it comes, one
/// after another; the table comes in close or stands back as another kind opens; and the sheet
/// springs from one shape to the next as sizes are pointed at. Its corner, which wears the
/// canvas's handle, pulls it to any size.
private struct SizeChart: View {
    let group: Preset.Group
    let shown: CGSize
    let shownPreset: Preset?
    let pointed: Preset?
    let pulling: Bool
    /// The size chosen, which the chart always has room for.
    let chosen: CGSize
    @Binding var width: Double
    @Binding var height: Double
    let appeared: Bool
    let pull: (CGSize?) -> Void
    let start: () -> Void
    @State private var room = CGSize(width: 700, height: 460)
    @State private var hovering = false
    @State private var shownYet = false
    /// The widths and heights the corner caught on last, to be felt once each time.
    @State private var caught: [CGFloat?] = [nil, nil]

    static let pad: CGFloat = 40
    /// Room above the sheet for its title.
    static let titleRoom: CGFloat = 40
    static let radius = SizeChartShape.radius

    private var presets: [Preset] { Preset.all(in: group) }

    /// The size the chart is drawn for: the largest of the open kind's sizes, and the one chosen.
    private var extent: CGSize {
        CGSize(width: max(presets.map(\.size.width).max() ?? 1, chosen.width), height: max(presets.map(\.size.height).max() ?? 1, chosen.height))
    }

    private var scale: CGFloat {
        let e = extent
        return max(min((room.width - Self.pad * 2) / e.width, (room.height - Self.pad * 2 - Self.titleRoom) / e.height), 0.01)
    }

    /// Where the sheets' shared corner is: the chart in the middle of the table.
    private var origin: CGPoint {
        let e = extent, s = scale
        return CGPoint(x: ((room.width - e.width * s) / 2).rounded(), y: (Self.pad + Self.titleRoom + (room.height - Self.pad * 2 - Self.titleRoom - e.height * s) / 2).rounded())
    }

    var body: some View {
        let s = scale, o = origin
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        shape
            .fill(Color(nsColor: CanvasInk.table))
            .overlay { TableRim(radius: Self.radius) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { room = $0 }
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(presets.enumerated()), id: \.element.id) { i, p in
                        SketchedOutline(on: pointed == p || (pointed == nil && shownPreset == p && pulling), order: i, shown: shownYet)
                            .frame(width: p.size.width * s, height: p.size.height * s)
                            .offset(x: o.x, y: o.y)
                            .transition(.opacity)
                    }
                    sheet(s, o)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text("Or drop a Bezzle, XD, Figma or Sketch file anywhere here")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
            }
            .clipShape(shape)
            .coordinateSpace(name: "chart")
            .onAppear { shownYet = appeared }
            .onChange(of: appeared) { _, now in shownYet = now }
    }

    private func sheet(_ s: CGFloat, _ o: CGPoint) -> some View {
        let w = max(shown.width * s, 4), h = max(shown.height * s, 4)
        let morph: Animation = pulling ? .interactiveSpring(response: 0.16, dampingFraction: 0.86) : .spring(response: 0.46, dampingFraction: 0.7)
        return ZStack(alignment: .topLeading) {
            title
                .offset(y: -Self.titleRoom + 2)
            Button(action: start) {
                Rectangle()
                    .fill(Paper.stock)
                    .shadow(color: CanvasShadow.color.opacity(hovering ? 0.26 : 0.16), radius: hovering ? 14 : 6, y: hovering ? 7 : 3)
                    .overlay {
                        Rectangle()
                            .strokeBorder(Theme.pencil, lineWidth: 1)
                            .opacity(hovering ? 1 : 0)
                    }
                    .overlay {
                        Label("New design", systemImage: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.pencil)
                            .labelStyle(.titleAndIcon)
                            .fixedSize()
                            .opacity(hovering && w > 96 && h > 30 ? 1 : 0)
                            .scaleEffect(hovering ? 1 : 0.92)
                    }
            }
            .buttonStyle(Pressable())
            .frame(width: w, height: h)
            .onHover { hovering = $0 }
            .help("Start a design \(Int(shown.width)) by \(Int(shown.height))")
            .accessibilityLabel("Start a design \(Int(shown.width)) by \(Int(shown.height))")
            handle(s, o)
                .offset(x: w - 6, y: h - 6)
        }
        .offset(x: o.x, y: o.y)
        .animation(morph, value: shown)
        .animation(Theme.quick, value: hovering)
        .opacity(shownYet ? 1 : 0)
        .offset(y: shownYet ? 0 : 10)
        .animation(.spring(response: 0.5, dampingFraction: 0.75).delay(0.55), value: shownYet)
    }

    /// The sheet's name and size over its corner, as the canvas titles an artboard; the size can
    /// be typed, and the sheet takes its shape.
    private var title: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(shownPreset?.title ?? "Your own size")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering || pulling ? Theme.pencil : Theme.ink2)
                .contentTransition(.opacity)
            HStack(spacing: 3) {
                if pointed != nil || pulling {
                    Text(verbatim: "\(Int(shown.width)) × \(Int(shown.height))")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(Theme.ink3)
                        .contentTransition(.numericText())
                } else {
                    PlainNumber(value: $width, submit: start)
                    Text(verbatim: "×")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.ink3)
                    PlainNumber(value: $height, submit: start)
                }
            }
            .frame(height: 15, alignment: .leading)
        }
        .lineLimit(1)
        .fixedSize()
    }

    /// The handle on the sheet's far corner, which pulls it to any size.
    private func handle(_ s: CGFloat, _ o: CGPoint) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(.white)
            .overlay { RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Theme.pencil, lineWidth: 1) }
            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
            .frame(width: pulling ? 14 : 12, height: pulling ? 14 : 12)
            .frame(width: 12, height: 12)
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("chart"))
                    .onChanged { value in pull(size(at: value.location, s, o)) }
                    .onEnded { value in
                        let size = size(at: value.location, s, o)
                        width = size.width
                        height = size.height
                        pull(nil)
                        caught = [nil, nil]
                    }
            )
            .pointerStyle(.frameResize(position: .bottomTrailing))
            .help("Drag the corner for a size of your own")
    }

    /// The size the corner makes at a point: whole tens, or, within a few points on screen, the
    /// width and height of another size of the open kind, felt as it catches.
    private func size(at p: CGPoint, _ s: CGFloat, _ o: CGPoint) -> CGSize {
        let reach = 7 / s
        func nearest(_ v: CGFloat, _ values: [CGFloat]) -> CGFloat? {
            values.min { abs($0 - v) < abs($1 - v) }.flatMap { abs($0 - v) <= reach ? $0 : nil }
        }
        let most = CGSize(width: (room.width - o.x - Self.pad / 2) / s, height: (room.height - o.y - Self.pad / 2) / s)
        let w = (p.x - o.x) / s, h = (p.y - o.y) / s
        let cw = nearest(w, presets.map(\.size.width)), ch = nearest(h, presets.map(\.size.height))
        if [cw, ch] != caught {
            if cw != nil && cw != caught[0] || ch != nil && ch != caught[1] {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            caught = [cw, ch]
        }
        let step: CGFloat = s < 0.2 ? 10 : 1
        return CGSize(width: min(max(cw ?? (w / step).rounded() * step, 20), max(most.width, 20)),
                      height: min(max(ch ?? (h / step).rounded() * step, 20), max(most.height, 20)))
    }
}

/// A size's outline on the table, dashed in pencil grey, drawn in from its corner as it comes:
/// after the screen first shows, or as its kind opens. Pointed at, it is drawn solid in pencil.
private struct SketchedOutline: View {
    let on: Bool
    /// Its place among the outlines, which sets how long it waits before it is drawn.
    let order: Int
    /// Whether the screen is showing yet.
    let shown: Bool
    @State private var drawn: CGFloat = 0

    var body: some View {
        Rectangle()
            .trim(from: 0, to: drawn)
            .stroke(on ? Theme.pencil : Theme.ink.opacity(0.24), style: StrokeStyle(lineWidth: on ? 1.5 : 1, dash: on ? [] : [4, 4]))
            .animation(Theme.quick, value: on)
            .onAppear { if shown { draw(after: 0.05) } }
            .onChange(of: shown) { _, now in if now { draw(after: 0.25) } }
    }

    private func draw(after wait: Double) {
        withAnimation(.easeInOut(duration: 0.8).delay(wait + Double(order) * 0.07)) { drawn = 1 }
    }
}

/// The white of a sheet of paper on the table, as an artboard is on the canvas.
private enum Paper {
    static let stock = Theme.dynamic(0xFFFFFF, 0xF4F1EB)
}

/// The soft shadow artboards cast on the table.
private enum CanvasShadow {
    static let color = Color(nsColor: CanvasInk.shadow)
}

/// A bare number for the custom size, set like the sizes under the other sheets' names, in a
/// faint well that shows it can be typed into.
private struct PlainNumber: View {
    @Binding var value: Double
    /// Return starts the design.
    var submit: (() -> Void)?
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(Theme.ink2)
            .multilineTextAlignment(.center)
            .focused($focused)
            .frame(width: 36, height: 15)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.ink.opacity(focused ? 0.1 : 0.06))
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
    }

    private func commit() {
        if let v = Double(draft), v >= 1, v <= 100_000 { value = v }
        draft = String(Int(value))
    }
}

// MARK: - Your designs

/// The corner radius the tables on the right share.
private enum SizeChartShape {
    static let radius: CGFloat = 16
}

/// Your designs as prints on small tables, in three or four columns across the room the size table
/// takes above them: the one changed last as large as four, across two columns and two rows, and
/// the others a column each. Every table has the same proportions and a name the same height under
/// it, so the rows and the names line up across the page.
private struct DesignGrid: View {
    let entries: [Library.Entry]
    let arriving: [CloudSync.Arrival]
    let problem: String?
    let dismissProblem: () -> Void
    /// Whether the one changed last is laid large, which it is not among what was looked for.
    let featured: Bool
    let appeared: Bool
    let open: (URL) -> Void
    @State private var width: CGFloat = 760

    static let gap: CGFloat = 22
    static let rowGap: CGFloat = 26

    private enum Item: Identifiable {
        case design(Library.Entry)
        case arriving(CloudSync.Arrival)
        case problem(String)

        var id: String {
            switch self {
            case .design(let e): e.url.path
            case .arriving(let a): "arriving-\(a.title)-\(a.owner ?? "")"
            case .problem: "problem"
            }
        }
    }

    var body: some View {
        let columns = width >= 1180 ? 4 : width >= 520 ? 3 : 2
        let column = max(((width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down), 60)
        let well = (column * 0.64).rounded()
        // As tall as two rows, so its name lines up with the second row's.
        let largeWell = well * 2 + DesignPlate.below + Self.rowGap
        let large = featured ? entries.first : nil
        let rest: [Item] = arriving.map(Item.arriving) + (problem.map { [Item.problem($0)] } ?? [])
            + entries.dropFirst(large == nil ? 0 : 1).map(Item.design)
        // Beside the large one, the columns it leaves, two rows deep.
        let side = columns - 2
        let beside = large != nil && side > 0 ? Array(rest.prefix(side * 2)) : []
        VStack(alignment: .leading, spacing: Self.rowGap) {
            if let large {
                HStack(alignment: .top, spacing: Self.gap) {
                    DesignPlate(entry: large, well: largeWell, large: true) { open(large.url) }
                        .frame(width: side > 0 ? column * 2 + Self.gap : width)
                        .rising(appeared, order: 13)
                    if !beside.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(column), spacing: Self.gap, alignment: .top), count: side),
                                  alignment: .leading, spacing: Self.rowGap) {
                            ForEach(Array(beside.enumerated()), id: \.element.id) { i, item in
                                tile(item, well: well)
                                    .rising(appeared, order: 14 + i)
                            }
                        }
                        .frame(width: column * CGFloat(side) + Self.gap * CGFloat(side - 1), alignment: .topLeading)
                    }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(column), spacing: Self.gap, alignment: .top), count: columns),
                      alignment: .leading, spacing: Self.rowGap) {
                ForEach(Array(rest.dropFirst(beside.count).enumerated()), id: \.element.id) { i, item in
                    tile(item, well: well)
                        .rising(appeared, order: 16 + min(i, 8))
                        .transition(.scale(scale: 0.94).combined(with: .opacity))
                }
            }
        }
        // As wide as the room it is given, never as wide as it last made itself: the columns
        // are worked out from this, and a frame no narrower than what it holds would never
        // let a wider grid narrow again.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    @ViewBuilder private func tile(_ item: Item, well: CGFloat) -> some View {
        switch item {
        case .design(let entry):
            DesignPlate(entry: entry, well: well) { open(entry.url) }
        case .arriving(let arrival):
            ArrivingCard(arrival: arrival, well: well)
        case .problem(let problem):
            UnopenedCard(problem: problem, well: well, dismiss: dismissProblem)
        }
    }
}

/// One of your designs: as it lies on the canvas's table, and under it its name and when it was
/// last changed. Pointed at, it lifts off the page.
private struct DesignPlate: View {
    @Environment(MenuHost.self) private var menus
    let entry: Library.Entry
    /// How tall its table is.
    let well: CGFloat
    /// The one changed last, laid large, with its name larger.
    var large = false
    let action: () -> Void
    @State private var hovering = false

    /// The room under the table for the name and the note under it.
    static let below: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DesignThumbnail(entry: entry, lifted: hovering, radius: large ? SizeChartShape.radius : 12)
                .frame(height: well)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(Theme.serif(large ? 19 : 15, weight: .medium))
                    .foregroundStyle(hovering ? Theme.pencil : Theme.ink)
                    .lineLimit(1)
                DesignNote(entry: entry)
            }
            .padding(.horizontal, 2)
            .padding(.top, large ? 11 : 12)
            .frame(height: Self.below, alignment: .topLeading)
        }
        .offset(y: hovering ? -3 : 0)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .menuAnchor("design-\(entry.url.path)")
        .contextMenuReplacement { point in menus.show(at: point, entries: DesignMenu.entries(for: entry, open: action)) }
        .animation(Theme.spring, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A field to look through your designs by name, in a well in the paper.
private struct SearchWell: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(focused ? Theme.ink2 : Theme.ink3)
            TextField("Search designs", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3)
                    .onTapGesture { text = "" }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.controlHeight)
        .well(radius: Theme.controlRadius)
    }
}

/// A design on the canvas's table, drawn as it lies there, coming in a little closer and lifting
/// off the page while it is pointed at.
private struct DesignThumbnail: View {
    let entry: Library.Entry
    let lifted: Bool
    var radius: CGFloat = 12

    var body: some View {
        ZStack {
            Color(nsColor: CanvasInk.table)
            if let image = Library.shared.thumbnail(for: entry, size: Library.thumbnailSize) {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
                    .scaleEffect(lifted ? 1.04 : 1)
            } else if !Library.shared.isMakingThumbnail(for: entry) {
                Text("Empty")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay { TableRim(radius: radius) }
        .background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.paper)
                .shadow(color: Theme.shadow.opacity(lifted ? 0.18 : 0), radius: lifted ? 18 : 6, y: lifted ? 10 : 3)
        }
    }
}

/// Whether a design is shared, and when it was last changed.
private struct DesignNote: View {
    let entry: Library.Entry

    var body: some View {
        HStack(spacing: 4) {
            if let mark = entry.sharing {
                Image(systemName: mark == .ended ? "lock.fill" : "person.2.fill")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(mark == .ended ? Theme.ink3 : Theme.pencil)
                Text(mark.title)
                    .foregroundStyle(mark == .ended ? Theme.ink3 : Theme.pencil)
                Text(verbatim: "·")
            }
            // Kept current on its own: drawn only as the card is, it would change as the
            // pointer comes over it, and the new date would ride the lift in.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(entry.modified.formatted(.relative(presentation: .named)))
                    .contentTransition(.identity)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.ink3)
        .lineLimit(1)
    }
}

/// What a right click on a design offers.
private enum DesignMenu {
    static func entries(for entry: Library.Entry, open: @escaping () -> Void) -> [MenuEntry] {
        [
            .item("Open") { open() },
            .item("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) },
            .item("Duplicate") { Library.shared.duplicate(entry.url) },
            .separator,
            .item(entry.url.path.hasPrefix(Library.shared.folder.path) ? "Move to Trash" : "Remove from List") {
                withAnimation(Theme.spring) { Library.shared.remove(entry.url) }
            },
        ]
    }
}

/// The rim of a table: a soft shadow along its top where it dips under the paper, and a
/// hairline round it.
private struct TableRim: View {
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .strokeBorder(Theme.shadow.opacity(0.2), lineWidth: 1.5)
            .blur(radius: 1.5)
            .offset(y: 1)
            .mask(shape)
            .overlay { shape.strokeBorder(Theme.hairline, lineWidth: 0.5) }
            .allowsHitTesting(false)
    }
}

/// A design someone shared, on its way from iCloud: a blank sheet settling onto its table while
/// what is on it is laid in, line by line, as it will be once it is here. It gives way to the
/// design's own card, in the same place, as soon as there is one.
private struct ArrivingCard: View {
    let arrival: CloudSync.Arrival
    let well: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color(nsColor: CanvasInk.table)
                TimelineView(.animation) { timeline in
                    ArrivingSheet(time: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
            .frame(height: well)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { TableRim(radius: 12) }
            VStack(alignment: .leading, spacing: 3) {
                Text(arrival.title)
                    .font(Theme.serif(15, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 8.5, weight: .semibold))
                    if let owner = arrival.owner { Text("Arriving from \(owner)") } else { Text("Arriving from iCloud") }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.pencil)
                .lineLimit(1)
            }
            .padding(.horizontal, 2)
            .padding(.top, 12)
            .frame(height: DesignPlate.below, alignment: .topLeading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(arrival.title), arriving")
    }
}

/// The sheet on an arriving card, at a moment: it drifts gently as it settles, and the lines on it
/// fill in one after another, pencil first, then ink, and start again.
private struct ArrivingSheet: View {
    let time: TimeInterval

    var body: some View {
        let drift = sin(time * 1.3)
        let lines: [CGFloat] = [0.78, 0.56, 0.9, 0.64, 0.42]
        let cycle = (time / 2.6).truncatingRemainder(dividingBy: 1)
        VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.ink4)
                .frame(width: 26, height: 5)
                .padding(.bottom, 3)
            ForEach(lines.indices, id: \.self) { i in
                let start = Double(i) * 0.13
                let laid = min(max((cycle - start) / 0.3, 0), 1)
                let eased = 1 - pow(1 - laid, 3)
                Capsule()
                    .fill(Theme.ink.opacity(0.06))
                    .frame(width: 44 * lines[i], height: 3)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(laid < 1 ? Theme.pencil.opacity(0.55) : Theme.ink4)
                            .frame(width: 44 * lines[i] * eased, height: 3)
                    }
            }
        }
        .padding(10)
        .frame(width: 66, height: 88, alignment: .topLeading)
        .background(Rectangle().fill(Paper.stock))
        .shadow(color: CanvasShadow.color.opacity(0.11 + 0.04 * drift), radius: 3.5 - drift, y: 2.2 - drift)
        .rotationEffect(.degrees(-1.2 + 1.1 * sin(time * 0.8)))
        .offset(y: -2 * drift)
    }
}

/// An invitation that could not be opened, in the place its design would have taken: the sheet
/// left lying askew, why, and a way to put it away.
private struct UnopenedCard: View {
    let problem: String
    let well: CGFloat
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color(nsColor: CanvasInk.table)
                Rectangle()
                    .fill(Paper.stock.opacity(0.7))
                    .overlay { Rectangle().strokeBorder(Theme.ink4, style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
                    .frame(width: 66, height: 88)
                    .rotationEffect(.degrees(-7))
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.warning)
                    .offset(x: 26, y: 30)
            }
            .frame(height: well)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { TableRim(radius: 12) }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Could not be opened")
                        .font(Theme.serif(15, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 4)
                    TextButton(title: "Dismiss", action: dismiss)
                        .padding(.trailing, -6)
                        .padding(.vertical, -4)
                }
                Text(problem)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                    .help(problem)
            }
            .padding(.horizontal, 2)
            .padding(.top, 12)
            .frame(height: DesignPlate.below, alignment: .topLeading)
        }
    }
}

/// Where your designs will be, before there are any: three blank sheets, and where to find them.
private struct NoDesigns: View {
    var body: some View {
        HStack(spacing: 22) {
            ZStack {
                ForEach(0..<3) { i in
                    Rectangle()
                        .fill(Paper.stock)
                        .shadow(color: CanvasShadow.color.opacity(0.14), radius: 2.5, y: 1.5)
                        .frame(width: 34, height: 46)
                        .rotationEffect(.degrees(Double(i - 1) * 9), anchor: .bottom)
                        .offset(x: CGFloat(i - 1) * 9)
                }
            }
            .frame(width: 84, height: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing here yet")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text("Designs you make are kept in Documents › Bezzle and show up here.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.ink.opacity(0.13), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
    }
}

/// What the window shows while a file is held over it.
private struct DropTarget: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.pencilWash)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.pencil.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [6, 7]))
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 24, weight: .light))
                Text("Drop to open")
                    .font(Theme.serif(19, weight: .medium))
            }
            .foregroundStyle(Theme.pencil)
        }
        .padding(10)
        .allowsHitTesting(false)
    }
}

extension View {
    /// A right click opens Bezzle's own menu where the pointer is, instead of the system's.
    func contextMenuReplacement(_ open: @escaping (CGPoint) -> Void) -> some View {
        overlay(RightClickCatcher(open: open))
    }
}

/// Catches right clicks over a view and reports where they landed in the window, measured from the top.
private struct RightClickCatcher: NSViewRepresentable {
    let open: (CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.open = open }

    final class CatcherView: NSView {
        var open: ((CGPoint) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only right clicks stop here; everything else goes to the views below.
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) { report(event) }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { report(event) } else { super.mouseDown(with: event) }
        }

        private func report(_ event: NSEvent) {
            let p = event.locationInWindow
            open?(CGPoint(x: p.x, y: (window?.contentView?.bounds.height ?? 0) - p.y))
        }
    }
}

/// Opens design windows from places without a SwiftUI environment: files opened from the Finder.
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()
    var openWindow: OpenWindowAction?
    var dismissWindow: DismissWindowAction?
    private var waiting: [URL] = []
    /// How many design windows are open, so the home screen can come back when the last one closes.
    var openDesigns = 0

    func open(_ url: URL) {
        guard let openWindow else { waiting.append(url); return }
        openWindow(id: "design", value: url.standardizedFileURL)
        // The home screen steps aside for the design, and comes back when the last one closes.
        dismissWindow?(id: "home")
    }

    func flush() {
        let urls = waiting
        waiting = []
        urls.forEach(open)
    }
}
