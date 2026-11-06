import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The first thing you see, the home tab, in one column: a greeting asking what is to be designed,
/// the families of sizes by name, and the open family's sizes standing side by side on a table at
/// one scale, each a click away from a design that size, with one of your own at the end. Then
/// your designs, latest first. The search and Open are in the window's bar, over it.
struct HomeView: View {
    @State private var library = Library.shared
    @State private var menus = MenuHost()
    @State private var dropping = false
    /// What your designs are being looked through for, typed into the bar along the top.
    private var search: String { Tabs.shared.homeSearch }
    /// Turns true as the screen first shows, so its parts can rise into place one after another.
    @State private var appeared = false
    /// How far the bar's controls keep from the window's right edge.
    static let edge: CGFloat = 20
    /// How far in from the window's sides the page keeps.
    static let margin: CGFloat = 40
    /// How wide the page grows at most; a wider window keeps it in the middle.
    static let maxWidth: CGFloat = 1240

    var body: some View {
        VStack(spacing: 0) {
            // Where the window's tab bar lies.
            Color.clear
                .frame(height: Theme.barHeight)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    StartArea(appeared: appeared) { size, name, slide in create(size, name: name, slide: slide) }
                        .padding(.bottom, 52)
                    recents
                }
                .frame(maxWidth: Self.maxWidth, alignment: .leading)
                .padding(.horizontal, Self.margin)
                .padding(.top, 14)
                .padding(.bottom, 56)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .edgeFade()
            #if DEBUG
            // BEZZLE_HOME_END=1 opens it at the bottom, to see your designs in a test run's snapshot.
            .defaultScrollAnchor(ProcessInfo.processInfo.environment["BEZZLE_HOME_END"] != nil ? .bottom : .top)
            #endif
        }
        .background(Theme.paper)
        .overlay {
            if dropping {
                DropTarget()
                    .transition(.opacity)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            // A link dropped from a browser is a page to bring in.
            if let page = urls.first(where: { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }) {
                WebImporting.shared.present(page.absoluteString)
                return true
            }
            let designs = urls.filter { BezzleDocument.fileExtensions.contains($0.pathExtension.lowercased()) || Importer.imports($0) }
            designs.forEach(open)
            return !designs.isEmpty
        } isTargeted: { over in withAnimation(Theme.spring) { dropping = over } }
        .overlayPreferenceValue(MenuAnchorKey.self) { MenuLayer(anchors: $0) }
        .environment(menus)
        .onAppear {
            library.refresh()
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

    private func create(_ size: CGSize, name: String, slide: CGSize? = nil) {
        guard let url = library.create(artboard: size, name: name, slide: slide) else { return }
        open(url)
    }

    private func open(_ url: URL) {
        WindowRouter.shared.open(url)
    }

    // MARK: Your designs

    /// Your designs under a heading of their own, in a grid as wide as the page.
    private var recents: some View {
        let sync = Sharing.shared
        let arriving = sync.arriving.sorted { $0.value.title < $1.value.title }.map(\.value)
        let query = search.trimmingCharacters(in: .whitespaces)
        let entries = query.isEmpty ? library.entries : library.entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("Your designs")
                    .font(Theme.serif(22, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if !library.entries.isEmpty {
                    Text(verbatim: library.entries.count.formatted())
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.ink3)
                }
                Spacer(minLength: 12)
                FolderButton(library: library)
                    .padding(.trailing, -8)
            }
            .rising(appeared, order: 4)
            Group {
                if library.entries.isEmpty && arriving.isEmpty && sync.invitationProblem == nil {
                    // Their places, kept for them, the first of them to open one with.
                    DesignGrid(entries: [], arriving: [], problem: nil, dismissProblem: {}, appeared: appeared) { open($0) }
                } else if entries.isEmpty && arriving.isEmpty {
                    Text("No design with that name")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink3)
                        .padding(.top, 4)
                } else {
                    DesignGrid(entries: entries, arriving: arriving, problem: sync.invitationProblem,
                               dismissProblem: { sync.invitationProblem = nil }, appeared: appeared) { open($0) }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
            .animation(Theme.spring, value: sync.arriving)
            .animation(Theme.spring, value: sync.invitationProblem)
            .animation(Theme.spring, value: entries.map(\.url))
        }
        .animation(Theme.spring, value: library.entries.isEmpty)
    }
}

extension View {
    /// Rises into place as the home screen first shows, after the parts before it.
    func rising(_ shown: Bool, order: Int) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .animation(Theme.spring.delay(0.04 + Double(order) * 0.035), value: shown)
    }

    /// Lets a row that scrolls sideways dissolve at an end where there is more of it, instead of
    /// being cut off there.
    func sideFade(length: CGFloat = 28) -> some View { modifier(SideFade(length: length)) }
}

private struct SideFade: ViewModifier {
    var length: CGFloat
    @State private var before = false
    @State private var after = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: [Bool].self) { g in
                [g.contentOffset.x > 1, g.contentOffset.x + g.containerSize.width < g.contentSize.width - 1]
            } action: { _, more in
                withAnimation(.easeOut(duration: 0.2)) { before = more[0]; after = more[1] }
            }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(before ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: length)
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(after ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: length)
                }
            }
    }
}

// MARK: - Your designs

/// Your designs as prints on small tables, all the same size, in as many columns as the page has
/// room for. Every table has the same proportions and a name the same height under it, so the
/// rows and the names line up across the page.
private struct DesignGrid: View {
    let entries: [Library.Entry]
    let arriving: [Sharing.Arrival]
    let problem: String?
    let dismissProblem: () -> Void
    let appeared: Bool
    let open: (URL) -> Void
    @State private var width: CGFloat = 1020

    static let gap: CGFloat = 22
    static let rowGap: CGFloat = 24
    /// How narrow a column may be before there is one fewer.
    static let narrowest: CGFloat = 220

    private enum Item: Identifiable {
        case design(Library.Entry)
        case arriving(Sharing.Arrival)
        case problem(String)

        var id: String {
            switch self {
            case .design(let e): e.key
            case .arriving(let a): "arriving-\(a.title)-\(a.owner ?? "")"
            case .problem: "problem"
            }
        }
    }

    var body: some View {
        let columns = max(Int((width + Self.gap) / (Self.narrowest + Self.gap)), 2)
        let column = max(((width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down), 60)
        // The proportions the thumbnails are drawn in.
        let well = (column * Library.thumbnailSize.height / Library.thumbnailSize.width).rounded()
        let items: [Item] = arriving.map(Item.arriving) + (problem.map { [Item.problem($0)] } ?? []) + entries.map(Item.design)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(column), spacing: Self.gap, alignment: .top), count: columns),
                  alignment: .leading, spacing: Self.rowGap) {
            if items.isEmpty {
                // Before there are any designs, a row of places for them: the first opens one,
                // and the others fade away along the row.
                OpenPlate(well: well)
                    .rising(appeared, order: 5)
                ForEach(1..<columns, id: \.self) { i in
                    GhostPlate(well: well, order: i)
                        .rising(appeared, order: 5 + i)
                }
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                tile(item, well: well)
                    .rising(appeared, order: 5 + min(i, 8))
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
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
/// last changed. Pointed at, it lifts off the page. Renamed from its menu, the name is typed anew
/// where it is.
private struct DesignPlate: View {
    @Environment(MenuHost.self) private var menus
    let entry: Library.Entry
    /// How tall its table is.
    let well: CGFloat
    let action: () -> Void
    @State private var hovering = false
    /// Where the pointer is over its table, from -0.5 to 0.5 each way.
    @State private var tilt = CGPoint.zero
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    /// The room under the table for the name and the note under it.
    static let below: CGFloat = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DesignThumbnail(entry: entry, lifted: hovering)
                .frame(height: well)
                // It tips a little towards the pointer, as a print held up to look at.
                .rotation3DEffect(.degrees(Double(tilt.y) * 5), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                .rotation3DEffect(.degrees(Double(tilt.x) * -6), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .onContinuousHover { phase in
                    withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.84)) {
                        switch phase {
                        case .active(let p): tilt = CGPoint(x: p.x / max(well / Library.thumbnailSize.height * Library.thumbnailSize.width, 1) - 0.5, y: p.y / max(well, 1) - 0.5)
                        case .ended: tilt = .zero
                        }
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                name
                DesignNote(entry: entry)
            }
            .padding(.horizontal, 2)
            .padding(.top, 11)
            .frame(height: Self.below, alignment: .topLeading)
        }
        .offset(y: hovering && !renaming ? -3 : 0)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // While its name is typed, a click on it only ends the typing.
        .gesture(TapGesture().onEnded(action), including: renaming ? .subviews : .all)
        .menuAnchor("design-\(entry.url.path)")
        .contextMenuReplacement { point in
            menus.show(at: point, entries: DesignMenu.entries(for: entry, open: action, rename: startRenaming))
        }
        .animation(Theme.spring, value: hovering)
        .animation(Theme.quick, value: renaming)
        // One button, but while its name is typed, the field stands on its own.
        .accessibilityElement(children: renaming ? .contain : .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { if !renaming { action() } }
        .accessibilityAction(named: Text("Rename"), startRenaming)
    }

    /// Its name, or while it is being renamed, a field in the paper holding it, in the same place.
    @ViewBuilder private var name: some View {
        if renaming {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(Theme.serif(15, weight: .medium))
                .foregroundStyle(Theme.ink)
                .focused($focused)
                .onSubmit { finishRenaming(keep: true) }
                .onExitCommand { finishRenaming(keep: false) }
                .onChange(of: focused) { _, now in if !now { finishRenaming(keep: true) } }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .well(radius: 7)
                .padding(.horizontal, -6)
                .padding(.vertical, -2)
        } else {
            Text(entry.name)
                .font(Theme.serif(15, weight: .medium))
                .foregroundStyle(hovering ? Theme.pencil : Theme.ink)
                .lineLimit(1)
        }
    }

    private func startRenaming() {
        guard entry.sharing?.renamable ?? true else { return }
        draft = entry.name
        renaming = true
        focused = true
    }

    private func finishRenaming(keep: Bool) {
        guard renaming else { return }
        renaming = false
        if keep { Library.shared.rename(entry.url, to: draft) }
    }
}

/// A field to look through your designs by name, in a well in the paper.
struct SearchWell: View {
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

/// A design on the canvas's table, drawn as it lies there: the whole of it, or for a large one
/// its largest artboard whole and the rest running off the edges. It comes in a little closer
/// and lifts off the page while it is pointed at.
private struct DesignThumbnail: View {
    let entry: Library.Entry
    let lifted: Bool
    var radius: CGFloat = 12

    var body: some View {
        Color(nsColor: CanvasInk.table)
            .overlay {
                if let image = Library.shared.thumbnail(for: entry, size: Library.thumbnailSize) {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(lifted ? 1.03 : 1)
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

/// The designs folder by its name, opening a menu to show it in the Finder or choose another.
private struct FolderButton: View {
    let library: Library
    @Environment(MenuHost.self) private var menus
    @State private var hovering = false
    private static let id = "designs-folder"

    var body: some View {
        let isOpen = menus.open?.id == Self.id
        HStack(spacing: 5) {
            Image(systemName: "folder")
                .font(.system(size: 11))
            Text(verbatim: library.folderName)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Chevron(color: hovering || isOpen ? Theme.ink : Theme.ink3)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
        }
        .foregroundStyle(hovering || isOpen ? Theme.ink : Theme.ink2)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.ink.opacity(isOpen ? 0.08 : hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            menus.toggle(Self.id, width: 220, entries: [
                .item("Show in Finder") { NSWorkspace.shared.open(library.folder) },
                // After the menu has gone, as the panel holds everything up while it is open.
                .item("Choose Folder…") { DispatchQueue.main.async { library.chooseFolder() } },
            ])
        }
        .menuAnchor(Self.id)
        .help(Text(verbatim: library.folder.path))
        .animation(Theme.quick, value: hovering)
        .animation(Theme.quick, value: isOpen)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// What a right click on a design offers.
private enum DesignMenu {
    static func entries(for entry: Library.Entry, open: @escaping () -> Void, rename: @escaping () -> Void) -> [MenuEntry] {
        [
            .item("Open") { open() },
            .item("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) },
            // Someone else's design keeps the name it was shared under, as in its tab.
            .item("Rename", enabled: entry.sharing?.renamable ?? true) { rename() },
            .item("Duplicate") { Library.shared.duplicate(entry.url) },
            .separator,
            .item(Library.shared.holds(entry.url) ? "Move to Trash" : "Remove from List") {
                guard Library.shared.mayTrash(entry.url) else { return }
                withAnimation(Theme.spring) { Library.shared.remove(entry.url) }
            },
        ]
    }
}

/// The rim of a table: a soft shadow along its top where it dips under the paper, and a
/// hairline round it.
struct TableRim: View {
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
    let arrival: Sharing.Arrival
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

/// The first place for a design, before there are any: a table outlined in pencil grey with a
/// file coming down into it. A click asks for a design to open, or a file from XD, Figma or
/// Sketch to bring in; a file can also be dropped anywhere on the page.
private struct OpenPlate: View {
    let well: CGFloat
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hovering ? Theme.pencilWash : .clear)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(hovering ? Theme.pencil.opacity(0.8) : Theme.ink.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(hovering ? Theme.pencil : Theme.ink3)
                    .offset(y: hovering ? 2 : 0)
            }
            .frame(height: well)
            VStack(alignment: .leading, spacing: 3) {
                Text("Open…")
                    .font(Theme.serif(15, weight: .medium))
                    .foregroundStyle(hovering ? Theme.pencil : Theme.ink)
                Text(verbatim: "Bezzle, XD, Figma, Sketch")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink3)
            }
            .lineLimit(1)
            .padding(.horizontal, 2)
            .padding(.top, 11)
            .frame(height: DesignPlate.below, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { WindowRouter.openPanel() }
        .animation(Theme.spring, value: hovering)
        .help("Open a design, or an XD, Figma, Sketch or Photoshop file  ⌘O")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A place kept for a design to come: a table outlined in pencil grey, and the marks of a name
/// and a date under it. The further along the row, the fainter.
private struct GhostPlate: View {
    let well: CGFloat
    let order: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.ink.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(height: well)
            VStack(alignment: .leading, spacing: 8) {
                Capsule()
                    .fill(Theme.ink.opacity(0.09))
                    .frame(width: 112 - CGFloat(order % 3) * 18, height: 8)
                Capsule()
                    .fill(Theme.ink.opacity(0.06))
                    .frame(width: 60, height: 6)
            }
            .padding(.horizontal, 2)
            .padding(.top, 16)
            .frame(height: DesignPlate.below, alignment: .topLeading)
        }
        .opacity(max(0.7 - Double(order - 1) * 0.22, 0.12))
        .accessibilityHidden(true)
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
