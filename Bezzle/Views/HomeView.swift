import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The first thing you see: a sheet of every size laid out on a table as the canvas lays out
/// artboards, to start a design on, and your designs, latest first.
struct HomeView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var library = Library.shared
    @State private var menus = MenuHost()
    @State private var customWidth: Double = 1200
    @State private var customHeight: Double = 800
    @State private var dropping = false
    /// Turns true as the screen first shows, so its parts can rise into place one after another.
    @State private var appeared = false

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
            .padding(.leading, 92)
            .padding(.trailing, 20)
            .frame(height: Theme.barHeight)
            // Above the designs below: their scroll view reaches up under the title bar, and
            // would otherwise take the clicks meant for Open.
            .zIndex(1)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    greeting
                        .rising(appeared, order: 0)
                        .padding(.bottom, 36)
                    SectionHead(title: "New design") {
                        Text("Or drop a Bezzle, XD, Figma or Sketch file anywhere here")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink3)
                    }
                    .rising(appeared, order: 1)
                    SizeTable(customWidth: $customWidth, customHeight: $customHeight, appeared: appeared) { size, name in
                        create(size, name: name)
                    }
                    .padding(.bottom, 44)
                    recents
                }
                .padding(.horizontal, 48)
                .padding(.top, 26)
                .padding(.bottom, 48)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .edgeFade()
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

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Theme.ink3)
            Text(Self.greeting(at: .now))
                .font(Theme.serif(34, weight: .medium))
                .foregroundStyle(Theme.ink)
        }
    }

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

    private var recents: some View {
        let sync = CloudSync.shared
        let arriving = sync.arriving.sorted { $0.value.title < $1.value.title }
        return VStack(alignment: .leading, spacing: 0) {
            SectionHead(title: "Your designs", count: library.entries.isEmpty ? nil : library.entries.count) {
                TextButton(title: "Show in Finder") { NSWorkspace.shared.open(library.folder) }
                    .padding(.trailing, -8)
            }
            .rising(appeared, order: 12)
            if library.entries.isEmpty && arriving.isEmpty && sync.invitationProblem == nil {
                NoDesigns()
                    .rising(appeared, order: 13)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 20)], alignment: .leading, spacing: 20) {
                    // A shared design on its way takes its place first, where it will be.
                    ForEach(arriving, id: \.key) { _, arrival in
                        ArrivingCard(arrival: arrival)
                            .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity), removal: .opacity))
                    }
                    if let problem = sync.invitationProblem {
                        UnopenedCard(problem: problem) { sync.invitationProblem = nil }
                            .transition(.scale(scale: 0.94).combined(with: .opacity))
                    }
                    ForEach(Array(library.entries.enumerated()), id: \.element.id) { i, entry in
                        DesignCard(entry: entry) { open(entry.url) }
                            .rising(appeared, order: 13 + min(i, 8))
                    }
                }
                .animation(Theme.spring, value: sync.arriving)
                .animation(Theme.spring, value: sync.invitationProblem)
                .animation(Theme.spring, value: library.entries.map(\.url))
            }
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

/// The head of a part of the home screen: its name on the left, set like the others, and one
/// quiet thing to do on the right.
private struct SectionHead<Trailing: View>: View {
    let title: LocalizedStringResource
    var count: Int?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(Theme.serif(20, weight: .medium))
                .foregroundStyle(Theme.ink)
            if let count {
                Text(verbatim: count.formatted())
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.ink3)
            }
            Spacer(minLength: 12)
            trailing
        }
        .frame(height: 28)
        .padding(.bottom, 14)
    }
}

// MARK: - The sizes

/// A sheet of every size, laid out on a table as the canvas lays out artboards: side by side at
/// one scale, so a watch and a desktop look as they really are beside each other, top edges in
/// line, each titled above its corner, and spread evenly across the table. Screens come first,
/// then social, print, and a sheet of your own size that takes the shape of what you type.
/// Pointing at one selects it as the canvas would, and a click starts a design on it. Where one
/// row would leave the sheets too small, the screens take a row and the rest another.
private struct SizeTable: View {
    @Binding var customWidth: Double
    @Binding var customHeight: Double
    let appeared: Bool
    let create: (CGSize, String) -> Void
    @State private var room: CGFloat = 1000

    static let order = ["Watch", "Phone", "Phone, large", "Tablet", "Laptop", "Desktop", "Social post", "Story", "A4"]
    /// Where the screens end and the rest begin, for two rows.
    static let rest = "Social post"
    /// The least room a sheet takes, for its title, however narrow it is.
    static let slot: CGFloat = 70
    static let customSlot: CGFloat = 92
    static let minGap: CGFloat = 14
    static let tallest: CGFloat = 132
    static let inset = EdgeInsets(top: 22, leading: 28, bottom: 26, trailing: 28)
    /// A title's two lines, and the space between it and its sheet.
    static let titleHeight: CGFloat = 31
    static let titleGap: CGFloat = 8
    static let rowGap: CGFloat = 26
    static let radius: CGFloat = 14

    fileprivate enum Item: Identifiable {
        case preset(Preset)
        case custom

        var id: String {
            switch self {
            case .preset(let p): p.id
            case .custom: "custom"
            }
        }
    }

    private var presets: [Preset] {
        Self.order.compactMap { name in Preset.all.first { $0.name == name } } + Preset.all.filter { !Self.order.contains($0.name) }
    }

    private func width(of item: Item, at scale: CGFloat) -> CGFloat {
        switch item {
        case .preset(let p): max(p.size.width * scale, Self.slot, Self.titleWidths[p.name] ?? 0)
        case .custom: max(Self.customSlot, Self.customTitleWidth)
        }
    }

    /// How wide each title is in the language shown, so a long one widens its sheet's slot rather
    /// than running into the next title.
    private static let titleWidths: [String: CGFloat] = Dictionary(uniqueKeysWithValues: Preset.all.map { ($0.name, titleWidth($0.title)) })
    private static let customTitleWidth = titleWidth("Your own size")

    private static func titleWidth(_ title: LocalizedStringResource) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        return ceil((String(localized: title) as NSString).size(withAttributes: [.font: font]).width)
    }

    private func sheets(_ row: [Item], at scale: CGFloat) -> CGFloat {
        row.reduce(0) { $0 + width(of: $1, at: scale) }
    }

    /// The tallest sheet in a row, which sets its height.
    private func height(of row: [Item], at scale: CGFloat) -> CGFloat {
        row.reduce(0) { tallest, item in
            if case .preset(let p) = item { max(tallest, p.size.height * scale) } else { tallest }
        }
    }

    /// The largest scale, up to `most`, at which every row fits across with at least the least gap.
    private func fitting(_ rows: [[Item]], in inner: CGFloat, most: CGFloat) -> CGFloat {
        func fits(_ scale: CGFloat) -> Bool {
            rows.allSatisfy { sheets($0, at: scale) + Self.minGap * CGFloat($0.count - 1) <= inner }
        }
        if fits(most) { return most }
        var low: CGFloat = 0, high = most
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if fits(mid) { low = mid } else { high = mid }
        }
        return low
    }

    private func layout(_ inner: CGFloat) -> (rows: [[Item]], scale: CGFloat, gap: CGFloat) {
        let items = presets.map(Item.preset) + [.custom]
        let most = Self.tallest / (presets.map(\.size.height).max() ?? 1)
        var rows = [items]
        var scale = fitting(rows, in: inner, most: most)
        if scale < most * 0.8 {
            let split = items.firstIndex { if case .preset(let p) = $0 { p.name == Self.rest } else { true } } ?? items.count
            rows = [Array(items[..<split]), Array(items[split...])]
            scale = max(fitting(rows, in: inner, most: most), most * 0.5)
        }
        // The first row spreads to fill the table, and a second keeps its spacing.
        let first = rows[0]
        let gap = max(Self.minGap, (inner - sheets(first, at: scale)) / CGFloat(max(first.count - 1, 1)))
        return (rows, scale, gap)
    }

    var body: some View {
        let inner = room - Self.inset.leading - Self.inset.trailing
        let (rows, scale, gap) = layout(inner)
        let heights = rows.map { height(of: $0, at: scale) }
        let total = Self.inset.top + Self.inset.bottom + Self.rowGap * CGFloat(rows.count - 1)
            + heights.reduce(0) { $0 + Self.titleHeight + Self.titleGap + $1 }
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        // The room is measured on the table rather than on what lies on it, which would
        // otherwise widen it to fit.
        shape
            .fill(Color(nsColor: CanvasInk.table))
            .overlay { TableRim(radius: Self.radius) }
            .frame(maxWidth: .infinity)
            .frame(height: total)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0 }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: Self.rowGap) {
                    ForEach(rows.indices, id: \.self) { r in
                        row(rows[r], scale: scale, gap: gap, area: heights[r], first: rows[..<r].reduce(0) { $0 + $1.count })
                    }
                }
                .padding(Self.inset)
            }
            .rising(appeared, order: 2)
    }

    private func row(_ row: [Item], scale: CGFloat, gap: CGFloat, area: CGFloat, first: Int) -> some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(Array(row.enumerated()), id: \.element.id) { i, item in
                Group {
                    switch item {
                    case .preset(let preset):
                        PresetSheet(preset: preset, drawn: CGSize(width: preset.size.width * scale, height: preset.size.height * scale), area: area) {
                            create(preset.size, String(localized: preset.title))
                        }
                    case .custom:
                        CustomSheet(width: $customWidth, height: $customHeight, scale: scale, area: area) {
                            create(CGSize(width: customWidth.rounded(), height: customHeight.rounded()), String(localized: "Artboard"))
                        }
                    }
                }
                .frame(width: width(of: item, at: scale), alignment: .leading)
                .rising(appeared, order: 3 + first + i)
            }
        }
    }
}

/// An artboard's title as the canvas writes it, over its top left corner: the name, and under
/// it the size. The name takes the pencil's blue while its sheet is selected, as on the canvas.
private struct SheetTitle<Size: View>: View {
    let name: LocalizedStringResource
    let selected: Bool
    @ViewBuilder let size: Size

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(selected ? Theme.pencil : Theme.ink2)
            size
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Theme.ink3)
        }
        .lineLimit(1)
        .fixedSize()
        .frame(height: SizeTable.titleHeight, alignment: .topLeading)
    }
}

/// One size on the table: its title, and its sheet.
private struct PresetSheet: View {
    let preset: Preset
    let drawn: CGSize
    /// The height of the tallest sheet in the row.
    let area: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: SizeTable.titleGap) {
                SheetTitle(name: preset.title, selected: hovering) {
                    Text(verbatim: "\(Int(preset.size.width)) × \(Int(preset.size.height))")
                }
                Paper(size: drawn, selected: hovering)
                    .frame(height: area, alignment: .top)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .help(Text(help))
        .accessibilityLabel("\(String(localized: preset.title)), \(Int(preset.size.width)) by \(Int(preset.size.height))")
    }

    /// What a click does, said whole for each size, as languages put a size and an artboard
    /// together differently.
    private var help: LocalizedStringResource {
        switch preset.name {
        case "Watch": "Start a design on a watch artboard"
        case "Phone": "Start a design on a phone artboard"
        case "Phone, large": "Start a design on a large phone artboard"
        case "Tablet": "Start a design on a tablet artboard"
        case "Laptop": "Start a design on a laptop artboard"
        case "Desktop": "Start a design on a desktop artboard"
        case "Social post": "Start a design on a social post artboard"
        case "Story": "Start a design on a story artboard"
        case "A4": "Start a design on an A4 artboard"
        default: "Start a design on an artboard this size"
        }
    }
}

/// A sheet of your own size, drawn dashed in the shape of what is typed: at the table's scale
/// when it fits, and smaller when it would not.
private struct CustomSheet: View {
    @Binding var width: Double
    @Binding var height: Double
    let scale: CGFloat
    let area: CGFloat
    let action: () -> Void
    @State private var hovering = false

    private var drawn: CGSize {
        let w = CGFloat(max(width, 1)), h = CGFloat(max(height, 1))
        let s = min(scale, SizeTable.customSlot / w, area / h)
        return CGSize(width: max(w * s, 8), height: max(h * s, 8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SizeTable.titleGap) {
            SheetTitle(name: "Your own size", selected: hovering) {
                HStack(spacing: 3) {
                    PlainNumber(value: $width, submit: action)
                    Text(verbatim: "×")
                    PlainNumber(value: $height, submit: action)
                }
            }
            Button(action: action) {
                Paper(size: drawn, selected: hovering, dashed: true)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(hovering ? Theme.pencil : Theme.ink3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: area, alignment: .top)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Pressable())
            .onHover { hovering = $0 }
            .help("Start a design on an artboard this size")
            .accessibilityLabel("Start a design \(Int(width)) by \(Int(height))")
        }
        .animation(Theme.spring, value: drawn)
        .animation(Theme.quick, value: hovering)
    }
}

/// A sheet of paper on the table, white as an artboard is on the canvas. Selected, it wears the
/// canvas's own selection, a pencil outline with a handle at each corner.
private struct Paper: View {
    let size: CGSize
    var selected = false
    /// Not a sheet yet: only its outline.
    var dashed = false

    static let stock = Theme.dynamic(0xFFFFFF, 0xF4F1EB)

    var body: some View {
        let shape = Rectangle()
        ZStack {
            if dashed {
                shape
                    .fill(selected ? Theme.pencilWash : .clear)
                    .overlay { shape.strokeBorder(selected ? Theme.pencil : Theme.ink4, style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
            } else {
                shape
                    .fill(Self.stock)
                    .shadow(color: CanvasShadow.color.opacity(selected ? 0.24 : 0.13), radius: selected ? 9 : 3, y: selected ? 4 : 1)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay {
            if selected && !dashed {
                SelectionMarks()
                    .padding(-3)
                    .transition(.opacity)
            }
        }
    }
}

/// The soft shadow artboards cast on the table.
private enum CanvasShadow {
    static let color = Color(nsColor: CanvasInk.shadow)
}

/// The canvas's selection, drawn the same: an outline on the edge and a square at each corner.
private struct SelectionMarks: View {
    var body: some View {
        Canvas { ctx, size in
            let edge = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
            ctx.stroke(Path(edge), with: .color(Theme.pencil), lineWidth: 1)
            for corner in [CGPoint(x: edge.minX, y: edge.minY), CGPoint(x: edge.maxX, y: edge.minY),
                           CGPoint(x: edge.maxX, y: edge.maxY), CGPoint(x: edge.minX, y: edge.maxY)] {
                let handle = Path(CGRect(x: corner.x - 2.5, y: corner.y - 2.5, width: 5, height: 5))
                ctx.fill(handle, with: .color(.white))
                ctx.stroke(handle, with: .color(Theme.pencil), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
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

private struct DesignCard: View {
    @Environment(MenuHost.self) private var menus
    let entry: Library.Entry
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The design as it lies on the canvas's table.
            ZStack {
                Color(nsColor: CanvasInk.table)
                if let image = Library.shared.thumbnail(for: entry, size: CGSize(width: 260, height: 160)) {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(10)
                        .scaleEffect(hovering ? 1.035 : 1)
                } else if !Library.shared.isMakingThumbnail(for: entry) {
                    Text("Empty")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink3)
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay { TableRim(radius: 9) }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
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
            .padding(.horizontal, 6)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
        .padding(5)
        .card(radius: SizeTable.radius, lifted: hovering)
        .offset(y: hovering ? -3 : 0)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .menuAnchor("design-\(entry.url.path)")
        .contextMenuReplacement { point in
            menus.show(at: point, entries: [
                .item("Open") { action() },
                .item("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) },
                .item("Duplicate") { Library.shared.duplicate(entry.url) },
                .separator,
                .item(entry.url.path.hasPrefix(Library.shared.folder.path) ? "Move to Trash" : "Remove from List") {
                    withAnimation(Theme.spring) { Library.shared.remove(entry.url) }
                },
            ])
        }
        .animation(Theme.spring, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color(nsColor: CanvasInk.table)
                TimelineView(.animation) { timeline in
                    ArrivingSheet(time: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay { TableRim(radius: 9) }
            VStack(alignment: .leading, spacing: 2) {
                Text(arrival.title)
                    .font(.system(size: 13, weight: .medium))
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
            .padding(.horizontal, 6)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
        .padding(5)
        .card(radius: SizeTable.radius)
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
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay { TableRim(radius: 9) }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Could not be opened")
                        .font(.system(size: 13, weight: .medium))
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
            .padding(.horizontal, 6)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
        .padding(5)
        .card(radius: SizeTable.radius)
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
            RoundedRectangle(cornerRadius: SizeTable.radius, style: .continuous)
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
