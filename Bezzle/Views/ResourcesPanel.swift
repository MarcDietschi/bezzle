import SwiftUI
import AppKit

/// Ready-made parts and icons, beside the tools in the layers list's place: a shelf of the kits
/// and icon sets, each opening as a page of its own, as an artboard does in the layers list.
/// Each part shows as itself, drawn as the canvas draws it, in the light or dark of the artboard
/// it would go onto. A click puts one onto that artboard; dragging one carries the real thing
/// onto the canvas, where it shows how it will land before it is let go.
struct ResourcesPanel: View {
    let store: DocumentStore
    @State private var page: ResourcePage?
    @State private var query = ""
    /// Which way the pages last turned: 1 into a library, -1 back out.
    @State private var way: CGFloat = 0
    /// Whether the artboard parts would go onto is dark, so they show dark.
    @State private var dark = false
    @State private var iconsReady = IconsLoading.done
    @FocusState private var searching: Bool

    /// A page and words to open on, once, for the debug hooks.
    static var opening: (ResourcePage?, String)?

    static let inner: CGFloat = 212
    static let gap: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ResourceSearch(query: $query, focused: $searching)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            ZStack(alignment: .topLeading) {
                content
                    .id(page)
                    .transition(.asymmetric(insertion: .offset(x: way * 36).combined(with: .opacity),
                                            removal: .offset(x: -way * 36).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .contentShape(Rectangle())
        .onAppear {
            lookAgain()
            if let (page, words) = Self.opening {
                self.page = page
                query = words
                Self.opening = nil
            }
        }
        .onChange(of: store.selection) { lookAgain() }
        // Other designs, as libraries, as they were last saved.
        .onAppear { LibraryShelf.shared.refresh(except: store.url) }
        .onChange(of: Library.shared.entries) { LibraryShelf.shared.refresh(except: store.url) }
        .task {
            guard !iconsReady else { return }
            await IconsLoading.load()
            iconsReady = true
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            PanelTitle(back: page == nil ? nil : { open(nil) })
            if let page {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.ink4)
                Text(verbatim: page.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .frame(height: 20)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        let words = query.trimmingCharacters(in: .whitespaces)
        switch page {
        case nil:
            if words.isEmpty {
                Shelf(store: store, dark: dark, iconsReady: iconsReady) { open($0) }
            } else {
                Found(store: store, query: words, dark: dark, iconsReady: iconsReady) { open($0) }
            }
        case .kit(let id):
            if let kit = Kits.kit(id) { KitPage(store: store, kit: kit, query: words, dark: dark) }
        case .icons(let id):
            if iconsReady { IconPage(store: store, set: Icons.set(id), query: words) } else { Color.clear }
        case .library(let url):
            LibraryPage(store: store, url: url, query: words)
        }
    }

    private func open(_ target: ResourcePage?) {
        way = target == nil ? -1 : 1
        withAnimation(Theme.unfold) { page = target }
    }

    /// Parts show as they would come out on the artboard they would go onto.
    private func lookAgain() {
        dark = Kits.isDark(store.focusedArtboard)
    }
}

/// A library open on its own page.
enum ResourcePage: Hashable {
    case kit(String)
    case icons(IconSetID)
    /// Another design, as a library of its components and styles.
    case library(URL)

    var title: String {
        switch self {
        case .library(let url): url.deletingPathExtension().lastPathComponent
        case .kit(let id): Kits.kit(id).map { String(localized: $0.title) } ?? id
        case .icons(let id): IconsLoading.done ? Icons.set(id).name : id.rawValue
        }
    }
}

/// The icon sets are read once, away from the main thread, the first time the panel opens.
@MainActor
enum IconsLoading {
    static var done = false

    static func load() async {
        guard !done else { return }
        // Read, and their words split for finding, before the first search.
        await Task.detached(priority: .userInitiated) { _ = Icons.search("a", limit: 1) }.value
        done = true
    }
}

/// The panel's title, which on a library's page is the way back to the shelf.
private struct PanelTitle: View {
    let back: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        Text("Resources")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(back == nil || hovering ? Theme.ink : Theme.ink3)
            .lineLimit(1)
            .fixedSize()
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { back?() }
            .animation(Theme.quick, value: hovering)
    }
}

/// Where words are typed to find parts and icons, pressed into the panel.
private struct ResourceSearch: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.ink3)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused(focused)
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3)
                    .contentShape(Rectangle())
                    .onTapGesture { query = "" }
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .well(radius: 8)
    }
}

// MARK: - The shelf

/// Every library: the kits, each shown by a few of its parts, and the icon sets by a few icons.
private struct Shelf: View {
    let store: DocumentStore
    let dark: Bool
    let iconsReady: Bool
    let open: (ResourcePage) -> Void

    private let columns = [GridItem(.fixed((ResourcesPanel.inner - ResourcesPanel.gap) / 2), spacing: ResourcesPanel.gap),
                           GridItem(.fixed((ResourcesPanel.inner - ResourcesPanel.gap) / 2), spacing: ResourcesPanel.gap)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // The design's own components first: what it is made of, to use again.
                if !store.doc.masters.isEmpty {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(store.doc.masters, id: \.id) { master in
                            OwnComponentTile(store: store, master: master, width: (ResourcesPanel.inner - ResourcesPanel.gap) / 2)
                        }
                    }
                    .transition(.opacity.combined(with: .offset(y: -6)))
                    Hairline()
                }
                // The other designs with components or styles of their own, to take from.
                let libraries = LibraryShelf.shared.libraries(except: store.url)
                if !libraries.isEmpty {
                    let news = Set(LibraryShelf.shared.news(for: store.doc, at: store.url).map(\.url))
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(libraries, id: \.url) { library in
                            LibraryCard(title: library.name, count: library.ownMasters.count + library.ownStyles.count, news: news.contains(library.url)) {
                                DesignLibraryCover(library: library)
                            } action: { open(.library(library.url)) }
                        }
                    }
                    .transition(.opacity.combined(with: .offset(y: -6)))
                    Hairline()
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Kits.all) { kit in
                        LibraryCard(title: String(localized: kit.title), count: kit.components.count) {
                            KitCover(kit: kit, dark: dark)
                        } action: { open(.kit(kit.id)) }
                    }
                }
                Hairline()
                VStack(spacing: 12) {
                    ForEach(IconSetID.allCases, id: \.self) { id in
                        LibraryCard(title: iconsReady ? Icons.set(id).name : " ", count: iconsReady ? Icons.set(id).icons.count : nil, coverHeight: 44) {
                            IconCover(set: id, ready: iconsReady)
                        } action: { open(.icons(id)) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.never)
        .edgeFade(length: 16)
    }
}

/// A library on the shelf: a picture of what is in it, its name and how much it holds.
struct LibraryCard<Cover: View>: View {
    let title: String
    let count: Int?
    var coverHeight: CGFloat = 76
    /// Whether it has news for the design: what was taken from it changed there since.
    var news = false
    @ViewBuilder let cover: Cover
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
                .frame(height: coverHeight)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                }
                .shadow(color: Theme.shadow.opacity(hovering ? 0.16 : 0.06), radius: hovering ? 8 : 3, y: hovering ? 4 : 1)
                .overlay(alignment: .topTrailing) {
                    if news {
                        Circle().fill(Theme.linked)
                            .overlay { Circle().strokeBorder(Theme.paper, lineWidth: 1.5) }
                            .frame(width: 10, height: 10)
                            .offset(x: 3, y: -3)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                }
                .scaleEffect(hovering ? 1.03 : 1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let count {
                    Text(verbatim: count.formatted())
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.ink3)
                }
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .animation(Theme.spring, value: hovering)
    }
}

/// A kit's cover: a few of its small parts on its paper.
private struct KitCover: View {
    let kit: Kit
    let dark: Bool
    @State private var thumbs = Thumbnails.shared

    var body: some View {
        ZStack {
            Color(nsColor: (dark ? kit.darkPaper : kit.paper).nsColor)
            if let image = thumbs.cover(kit, dark: dark) {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(8)
            }
        }
    }
}

/// An icon set's cover: a row of its icons.
private struct IconCover: View {
    let set: IconSetID
    let ready: Bool

    private static let samples: [IconSetID: [String]] = [
        .lucide: ["heart", "bell", "camera", "house", "search", "settings", "send"],
        .phosphor: ["heart", "bell", "camera", "house", "magnifying-glass", "gear", "paper-plane-tilt"],
        .material: ["favorite", "notifications", "photo_camera", "home", "search", "settings", "send"],
    ]

    var body: some View {
        ZStack {
            Theme.card
            if ready {
                let s = Icons.set(set)
                HStack(spacing: 0) {
                    ForEach(Self.samples[set] ?? [], id: \.self) { name in
                        if let icon = s.icon(name) {
                            IconGlyph(icon: icon, set: s, style: s.defaultStyle, size: 18)
                                .foregroundStyle(Theme.ink)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }
}

// MARK: - A kit

/// A kit's parts by section, each drawn as itself; wide parts take the whole width.
private struct KitPage: View {
    let store: DocumentStore
    let kit: Kit
    let query: String
    let dark: Bool

    var body: some View {
        let shown = sections
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { section in
                    Text(section.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                        .padding(.top, 6)
                        .padding(.bottom, 8)
                    PartRows(store: store, parts: section.components.map { (kit, $0) }, dark: dark)
                        .padding(.bottom, 10)
                }
                if shown.isEmpty { NothingFound() }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.never)
        .edgeFade(length: 16)
    }

    private var sections: [KitSection] {
        guard !query.isEmpty else { return kit.sections }
        let found = Set(Kits.search(query).filter { $0.kit.id == kit.id }.map(\.component.id))
        return kit.sections.compactMap { s in
            let parts = s.components.filter { found.contains($0.id) }
            return parts.isEmpty ? nil : KitSection(title: s.title, components: parts)
        }
    }
}

/// Parts laid in rows: a wide one alone, small ones two by two.
private struct PartRows: View {
    let store: DocumentStore
    let parts: [(kit: Kit, component: Component)]
    let dark: Bool
    /// Whether each says which kit it is from, among parts of several.
    var kits = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: ResourcesPanel.gap) {
                    ForEach(row, id: \.component.id) { part in
                        PartTile(store: store, kit: part.kit, component: part.component, dark: dark, showsKit: kits,
                                 width: row.count == 1 && Self.isWide(part.component) ? ResourcesPanel.inner : (ResourcesPanel.inner - ResourcesPanel.gap) / 2)
                    }
                }
            }
        }
    }

    /// Wider than half the panel holds at a readable size, or a bar.
    static func isWide(_ c: Component) -> Bool {
        c.size.width > 190 || c.size.width / max(c.size.height, 1) > 4.5
    }

    private var rows: [[(kit: Kit, component: Component)]] {
        var rows: [[(kit: Kit, component: Component)]] = []
        var waiting: (kit: Kit, component: Component)?
        for part in parts {
            if Self.isWide(part.component) {
                if let w = waiting { rows.append([w]); waiting = nil }
                rows.append([part])
            } else if let w = waiting {
                rows.append([w, part])
                waiting = nil
            } else {
                waiting = part
            }
        }
        if let w = waiting { rows.append([w]) }
        return rows
    }
}

/// One part, drawn as it would come out, on its kit's paper, with its name under it. A click
/// adds it to the artboard in view; a drag carries it onto the canvas.
/// One of the design's components on the shelf, drawn as a new copy of it would look: a click
/// puts a copy onto the artboard in view, a drag carries one onto the canvas.
private struct OwnComponentTile: View {
    let store: DocumentStore
    let master: Node
    let width: CGFloat
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        let image = ComponentPictures.image(of: master, store: store, size: CGSize(width: width - 12, height: 64))
        let count = store.doc.copies(of: master.id).count
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                Theme.card
                if let image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                }
            }
            .frame(width: width, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(hovering ? Theme.linked.opacity(0.6) : Theme.hairline, lineWidth: 1)
            }
            .shadow(color: Theme.shadow.opacity(hovering ? 0.16 : 0.05), radius: hovering ? 8 : 2, y: hovering ? 4 : 1)
            .scaleEffect(pressed ? 0.97 : hovering ? 1.02 : 1)
            .overlay {
                DragSource(resource: .design(master.id), tip: master.name,
                           picture: { Thumbnails.picture(image, width: min(width * 0.9, 180)) },
                           hovering: $hovering, pressed: $pressed) {
                    store.place(.design(master.id))
                    if let canvas = store.canvas { canvas.window?.makeFirstResponder(canvas) }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                ComponentGlyph(size: 9).foregroundStyle(Theme.linked)
                Text(verbatim: master.name)
                    .foregroundStyle(hovering ? Theme.ink : Theme.ink2)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(verbatim: count.formatted())
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.ink3)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 2)
        }
        .frame(width: width, alignment: .leading)
        .contextMenu {
            Button("Delete Component") { store.deleteComponent(master.id) }
        }
        .help(Text("\(count) copies in this design"))
        .animation(Theme.spring, value: hovering)
        .animation(Theme.quick, value: pressed)
    }
}

private struct PartTile: View {
    let store: DocumentStore
    let kit: Kit
    let component: Component
    let dark: Bool
    var showsKit = false
    let width: CGFloat
    @State private var thumbs = Thumbnails.shared
    @State private var hovering = false
    @State private var pressed = false

    /// A tile as tall as the part shows at in it, never drawn bigger than it is.
    private var height: CGFloat {
        guard width >= ResourcesPanel.inner else { return 72 }
        let sheet = Thumbnails.sheet(for: component.size)
        let k = min(1, (width - 12) / sheet.width)
        return min(max(sheet.height * k + 12, 44), 150).rounded()
    }

    var body: some View {
        let thumb = thumbs.part(component, dark: dark, paper: dark ? kit.darkPaper : kit.paper)
        let image = thumb?.image
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                Color(nsColor: (dark ? kit.darkPaper : kit.paper).nsColor)
                if let thumb {
                    let k = min(1, (width - 12) / thumb.size.width, (height - 12) / thumb.size.height)
                    Image(decorative: thumb.image, scale: 2)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: thumb.size.width * k, height: thumb.size.height * k)
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(hovering ? Theme.pencil.opacity(0.5) : Theme.hairline, lineWidth: 1)
            }
            .shadow(color: Theme.shadow.opacity(hovering ? 0.16 : 0.05), radius: hovering ? 8 : 2, y: hovering ? 4 : 1)
            .scaleEffect(pressed ? 0.97 : hovering ? 1.02 : 1)
            .overlay {
                DragSource(resource: .component(component.id), tip: String(localized: component.title),
                           picture: { Thumbnails.picture(image, width: min(width * 0.9, 180)) },
                           hovering: $hovering, pressed: $pressed) {
                    store.place(.component(component.id))
                    if let canvas = store.canvas { canvas.window?.makeFirstResponder(canvas) }
                }
            }
            HStack(spacing: 4) {
                Text(component.title)
                    .foregroundStyle(hovering ? Theme.ink : Theme.ink2)
                if showsKit {
                    Text(kit.title)
                        .foregroundStyle(Theme.ink3)
                }
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .padding(.horizontal, 2)
        }
        .frame(width: width, alignment: .leading)
        .animation(Theme.spring, value: hovering)
        .animation(Theme.quick, value: pressed)
    }
}

// MARK: - Icons

/// An icon set: its styles as a strip of one icon drawn in each, and every icon under them.
private struct IconPage: View {
    let store: DocumentStore
    let set: IconSet
    let query: String
    @AppStorage("resources.iconStyles") private var saved = ""

    var body: some View {
        let style = Self.style(for: set, in: saved)
        let icons = query.isEmpty ? set.icons : Icons.search(query, in: set.id)
        VStack(alignment: .leading, spacing: 10) {
            StyleStrip(set: set, style: style) { saved = Self.saving($0, for: set, in: saved) }
                .padding(.horizontal, 12)
            ScrollView {
                IconGrid(store: store, set: set, icons: icons, style: style)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                if icons.isEmpty { NothingFound().padding(.horizontal, 12) }
            }
            .scrollIndicators(.never)
            .edgeFade(length: 16)
        }
    }

    /// The style last picked for a set, kept as "lucide=0:2;phosphor=4:2".
    static func style(for set: IconSet, in saved: String) -> IconStyle {
        for entry in saved.split(separator: ";") {
            let parts = entry.split(separator: "=")
            guard parts.count == 2, parts[0] == set.id.rawValue else { continue }
            let v = parts[1].split(separator: ":")
            if v.count == 2, let i = Int(v[0]), let w = Double(v[1]), set.styles.indices.contains(i) {
                return IconStyle(index: i, weight: CGFloat(w))
            }
        }
        return set.defaultStyle
    }

    static func saving(_ style: IconStyle, for set: IconSet, in saved: String) -> String {
        var entries = saved.split(separator: ";").map(String.init).filter { !$0.hasPrefix(set.id.rawValue + "=") }
        entries.append("\(set.id.rawValue)=\(style.index):\(style.weight)")
        return entries.joined(separator: ";")
    }
}

/// One icon drawn in each style the set has, or at each weight for a set of lines: the one
/// picked sits in a well. What the icons below are drawn in, and what they come in as.
private struct StyleStrip: View {
    let set: IconSet
    let style: IconStyle
    let pick: (IconStyle) -> Void

    private var choices: [(IconStyle, LocalizedStringResource)] {
        if set.drawnAsLines {
            return [(1, Self.thin), (1.5, Self.light), (2, Self.regular), (2.5, Self.bold), (3, Self.heavy)].map { (IconStyle(index: 0, weight: $0.0), $0.1) }
        }
        return set.styles.enumerated().map { i, name in
            let title: LocalizedStringResource = switch name {
            case "thin": Self.thin
            case "light": Self.light
            case "regular": Self.regular
            case "bold": Self.bold
            case "fill": Self.filled
            case "outline": Self.outlined
            default: .verbatim(name)
            }
            return (IconStyle(index: i, weight: style.weight), title)
        }
    }

    // Weights of lines, which "Light" and "Bold" mean elsewhere in other ways.
    static let thin = LocalizedStringResource("icon.thin", defaultValue: "Thin")
    static let light = LocalizedStringResource("icon.light", defaultValue: "Light")
    static let regular = LocalizedStringResource("icon.regular", defaultValue: "Regular")
    static let bold = LocalizedStringResource("icon.bold", defaultValue: "Bold")
    static let heavy = LocalizedStringResource("icon.heavy", defaultValue: "Heavy")
    static let filled = LocalizedStringResource("icon.filled", defaultValue: "Filled")
    static let outlined = LocalizedStringResource("icon.outlined", defaultValue: "Outlined")

    var body: some View {
        let sample = set.icon("star") ?? set.icons.first
        HStack(spacing: 4) {
            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                let on = set.drawnAsLines ? abs(choice.0.weight - style.weight) < 0.01 : choice.0.index == style.index
                StyleChoice(on: on, help: choice.1) {
                    if let sample { IconGlyph(icon: sample, set: set, style: choice.0, size: 18) }
                } action: { pick(choice.0) }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct StyleChoice<Glyph: View>: View {
    let on: Bool
    let help: LocalizedStringResource
    @ViewBuilder let glyph: Glyph
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        glyph
            .foregroundStyle(on || hovering ? Theme.ink : Theme.ink2)
            .frame(width: 36, height: 30)
            .background {
                if on {
                    Color.clear.well(radius: 8)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink.opacity(hovering ? 0.06 : 0))
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .help(Text(help))
            .animation(Theme.quick, value: hovering)
            .animation(Theme.spring, value: on)
    }
}

/// Icons six to a row, each one a click or a drag away from the canvas.
private struct IconGrid: View {
    let store: DocumentStore
    let set: IconSet
    let icons: [Icon]
    let style: IconStyle

    static let cell: CGFloat = 32
    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(Self.cell), spacing: (ResourcesPanel.inner - Self.cell * 6) / 5), count: 6)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(icons, id: \.name) { icon in
                IconCell(store: store, icon: icon, set: set, style: style)
            }
        }
    }
}

private struct IconCell: View {
    let store: DocumentStore
    let icon: Icon
    let set: IconSet
    let style: IconStyle
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        IconGlyph(icon: icon, set: set, style: style, size: 20)
            .foregroundStyle(hovering ? Theme.ink : Theme.ink.opacity(0.82))
            .frame(width: IconGrid.cell, height: IconGrid.cell)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Theme.pencilWash : .clear)
            }
            .scaleEffect(pressed ? 0.9 : hovering ? 1.08 : 1)
            .overlay {
                DragSource(resource: .icon(set.id, icon.name, style), tip: icon.words,
                           picture: { Thumbnails.iconPicture(icon, set: set, style: style) },
                           hovering: $hovering, pressed: $pressed) {
                    store.place(.icon(set.id, icon.name, style), on: store.selection.count == 1 && store.node(store.selection[0]).map(Icons.isIcon) == true ? store.selection[0] : nil)
                    if let canvas = store.canvas { canvas.window?.makeFirstResponder(canvas) }
                }
            }
            .animation(Theme.quick, value: hovering)
            .animation(Theme.quick, value: pressed)
    }
}

/// An icon drawn as it will come in: a set of lines stroked at its weight, round at the ends
/// and corners, others filled.
struct IconGlyph: View {
    let icon: Icon
    let set: IconSet
    let style: IconStyle
    var size: CGFloat = 20

    var body: some View {
        Canvas { ctx, s in
            let path = IconPaths.path(icon, style: style)
            let k = size / max(set.box.width, 1)
            let t = CGAffineTransform(translationX: (s.width - size) / 2, y: (s.height - size) / 2)
                .scaledBy(x: k, y: k)
                .translatedBy(x: -set.box.minX, y: -set.box.minY)
            let p = Path(path).applying(t)
            if set.drawnAsLines {
                ctx.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: style.weight * size / 24, lineCap: .round, lineJoin: .round))
            } else {
                ctx.fill(p, with: .foreground)
            }
        }
        .frame(width: size + 4, height: size + 4)
    }
}

/// Icons' outlines read once each, as the grid draws them again and again.
nonisolated enum IconPaths {
    private static let kept = Shared([String: CGPath]())

    static func path(_ icon: Icon, style: IconStyle) -> CGPath {
        let i = icon.paths.indices.contains(style.index) && !icon.paths[style.index].isEmpty ? style.index : 0
        let key = "\(icon.set.rawValue)/\(icon.name)/\(i)"
        if let p = kept.with({ $0[key] }) { return p }
        let p = PathData.cgPath(icon.paths.indices.contains(i) ? icon.paths[i] : "")
        kept.with {
            if $0.count > 6000 { $0.removeAll() }
            $0[key] = p
        }
        return p
    }
}

// MARK: - Found

/// What fits the words typed, across every library: parts, then each icon set's best few.
private struct Found: View {
    let store: DocumentStore
    let query: String
    let dark: Bool
    let iconsReady: Bool
    let open: (ResourcePage) -> Void
    @AppStorage("resources.iconStyles") private var saved = ""

    private static let iconsShown = 18

    var body: some View {
        let parts = Kits.search(query)
        let icons: [(IconSet, [Icon])] = iconsReady ? Icons.sets.map { ($0, Icons.search(query, in: $0.id)) }.filter { !$0.1.isEmpty } : []
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // The components of other designs called so, first: the user's own.
                let theirs = LibraryShelf.shared.libraries(except: store.url).map { lib in
                    (lib, lib.ownMasters.filter { $0.name.localizedCaseInsensitiveContains(query) })
                }.filter { !$0.1.isEmpty }
                ForEach(theirs, id: \.0.url) { library, found in
                    LibraryComponents(store: store, library: library, masters: found, showsDesign: true)
                        .padding(.bottom, 14)
                }
                if !parts.isEmpty {
                    PartRows(store: store, parts: parts, dark: dark, kits: true)
                        .padding(.bottom, 14)
                }
                ForEach(icons, id: \.0.id) { set, found in
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: set.name)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.ink3)
                        Spacer()
                        if found.count > Self.iconsShown {
                            MoreLink(count: found.count) { open(.icons(set.id)) }
                        }
                    }
                    .padding(.bottom, 6)
                    IconGrid(store: store, set: set, icons: Array(found.prefix(Self.iconsShown)), style: IconPage.style(for: set, in: saved))
                        .padding(.bottom, 14)
                }
                if parts.isEmpty && icons.isEmpty && theirs.isEmpty { NothingFound() }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.never)
        .edgeFade(length: 16)
    }
}

/// How many more there are, which opens them all.
private struct MoreLink: View {
    let count: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(verbatim: count.formatted())
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(hovering ? Theme.pencil : Theme.ink3)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(hovering ? Theme.pencilWash : Theme.ink.opacity(0.05)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .animation(Theme.quick, value: hovering)
    }
}

/// Nothing fits what was typed: the search glass, faint, with a question in it.
struct NothingFound: View {
    var body: some View {
        HStack {
            Spacer()
            Image(systemName: "questionmark.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.ink4)
                .padding(.vertical, 28)
            Spacer()
        }
    }
}

// MARK: - Pictures

/// Parts drawn small for the panel, away from the main thread, once each for light and dark.
@MainActor @Observable
final class Thumbnails {
    static let shared = Thumbnails()

    /// A part drawn on its paper, and how big that sheet is in points.
    struct Thumb {
        let image: CGImage
        let size: CGSize
    }

    private var images: [String: Thumb] = [:]
    @ObservationIgnored private var asked: Set<String> = []

    /// The part drawn on its paper, or nil while it is being drawn.
    func part(_ c: Component, dark: Bool, paper: RGBA) -> Thumb? {
        let key = "\(c.id)|\(dark)"
        if let image = images[key] { return image }
        guard !asked.contains(key) else { return nil }
        asked.insert(key)
        Task.detached(priority: .userInitiated) {
            let made = Self.draw([c.node(dark: dark)], paper: paper)
            await MainActor.run { if let made { Thumbnails.shared.images[key] = Thumb(image: made.image, size: made.size) } }
        }
        return nil
    }

    /// A few of a kit's small parts, side by side.
    func cover(_ kit: Kit, dark: Bool) -> CGImage? {
        let key = "cover:\(kit.id)|\(dark)"
        if let thumb = images[key] { return thumb.image }
        guard !asked.contains(key) else { return nil }
        asked.insert(key)
        let paper = dark ? kit.darkPaper : kit.paper
        let small = kit.components.filter { !$0.stretches && $0.size.width <= 160 && $0.size.height <= 64 }.prefix(4)
        Task.detached(priority: .utility) {
            var nodes: [Node] = []
            var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
            for (i, c) in small.enumerated() {
                var n = c.node(dark: dark)
                if i == 2 { x = 0; y += rowHeight + 14; rowHeight = 0 }
                n.frame.origin = CGPoint(x: x, y: y)
                x += n.frame.width + 14
                rowHeight = max(rowHeight, n.frame.height)
                nodes.append(n)
            }
            let made = Self.draw(nodes, paper: paper)
            await MainActor.run { if let made { Thumbnails.shared.images[key] = Thumb(image: made.image, size: made.size) } }
        }
        return nil
    }

    private struct Made: @unchecked Sendable {
        let image: CGImage
        let size: CGSize
    }

    /// How big the sheet a part of this size is drawn on is: the part with a margin round it.
    nonisolated static func sheet(for size: CGSize) -> CGSize {
        let pad = margin(size)
        return CGSize(width: size.width + pad * 2, height: size.height + pad * 2)
    }

    nonisolated private static func margin(_ size: CGSize) -> CGFloat {
        max(6, min(size.width, size.height) * 0.08)
    }

    /// Layers drawn on a sheet of paper a little bigger than they are, at most about as many
    /// pixels as the panel shows them at.
    nonisolated private static func draw(_ nodes: [Node], paper: RGBA) -> Made? {
        guard let box = nodes.map({ Geometry.bounds(of: $0) }).reduce(nil as CGRect?, { $0?.union($1) ?? $1 }) else { return nil }
        let pad = margin(box.size)
        let sheet = box.insetBy(dx: -pad, dy: -pad)
        var board = Node(kind: .artboard, name: "Thumbnail", frame: sheet)
        board.fill = Fill(color: paper)
        board.children = nodes.map { var n = $0; n.frame = n.frame.offsetBy(dx: -sheet.minX, dy: -sheet.minY); return n }
        let scale = min(2, 460 / sheet.width, 320 / sheet.height)
        return Renderer.image(of: board, scale: scale).map { Made(image: $0, size: sheet.size) }
    }

    /// What the pointer carries while a part is dragged: its picture, at most `width` across.
    static func picture(_ image: CGImage?, width: CGFloat) -> NSImage? {
        guard let image else { return nil }
        let k = min(1, width / (CGFloat(image.width) / 2))
        let size = CGSize(width: CGFloat(image.width) / 2 * k, height: CGFloat(image.height) / 2 * k)
        let picture = NSImage(size: size)
        picture.addRepresentation(NSBitmapImageRep(cgImage: image))
        picture.representations.first?.size = size
        return picture
    }

    /// An icon drawn in ink at 28 points, for carrying.
    static func iconPicture(_ icon: Icon, set: IconSet, style: IconStyle) -> NSImage {
        let node = Icons.node(icon, style: style, frame: CGRect(x: 0, y: 0, width: 28, height: 28), color: RGBA(NSColor.labelColor))
        return NSImage(size: CGSize(width: 28, height: 28), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            Renderer.drawNode(node, in: ctx, options: Renderer.Options(deviceScale: 2))
            return true
        }
    }
}

// MARK: - Carrying

/// Lies over a part or an icon in the panel and starts carrying it when it is dragged, with
/// its picture under the pointer; a click without a drag picks it. AppKit's own drag, so the
/// canvas can take the picture away and show the real thing where it will land.
struct DragSource: NSViewRepresentable {
    let resource: Resource
    let tip: String
    let picture: () -> NSImage?
    @Binding var hovering: Bool
    @Binding var pressed: Bool
    let click: () -> Void

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        update(view)
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) { update(view) }

    private func update(_ view: DragSourceView) {
        view.resource = resource
        view.picture = picture
        view.click = click
        view.toolTip = tip
        let hovering = $hovering, pressed = $pressed
        view.hovering = { hovering.wrappedValue = $0 }
        view.pressing = { pressed.wrappedValue = $0 }
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var resource: Resource?
    var picture: () -> NSImage? = { nil }
    var click: () -> Void = {}
    var hovering: (Bool) -> Void = { _ in }
    var pressing: (Bool) -> Void = { _ in }
    private var down: NSPoint?
    private var dragged = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering(true) }
    override func mouseExited(with event: NSEvent) { hovering(false) }

    override func mouseDown(with event: NSEvent) {
        down = event.locationInWindow
        dragged = false
        pressing(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down, !dragged, let resource else { return }
        let p = event.locationInWindow
        guard hypot(p.x - down.x, p.y - down.y) > 3 else { return }
        dragged = true
        pressing(false)
        let item = NSPasteboardItem()
        item.setString(resource.key, forType: ResourceDrag.type)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = picture() ?? NSImage(size: CGSize(width: 32, height: 32))
        let at = convert(event.locationInWindow, from: nil)
        dragging.setDraggingFrame(CGRect(x: at.x - image.size.width / 2, y: at.y - image.size.height / 2,
                                         width: image.size.width, height: image.size.height), contents: image)
        ResourceDrag.current = resource
        ResourceDrag.picture = image
        let session = beginDraggingSession(with: [dragging], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        pressing(false)
        defer { down = nil }
        guard down != nil, !dragged else { return }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { click() }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        ResourceDrag.current = nil
        ResourceDrag.picture = nil
        hovering(false)
    }
}

/// The resources switch on the tool rail: four small shapes, a square, a circle, a triangle and
/// a star, in the same hand as the tools.
struct ResourcesGlyph: View {
    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let style = StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
            ctx.stroke(Path(roundedRect: CGRect(x: w * 0.13, y: h * 0.13, width: w * 0.30, height: h * 0.30), cornerRadius: 1.6), with: .foreground, style: style)
            ctx.stroke(Path(ellipseIn: CGRect(x: w * 0.57, y: h * 0.13, width: w * 0.30, height: h * 0.30)), with: .foreground, style: style)
            var tri = Path()
            tri.move(to: CGPoint(x: w * 0.28, y: h * 0.57))
            tri.addLine(to: CGPoint(x: w * 0.44, y: h * 0.86))
            tri.addLine(to: CGPoint(x: w * 0.12, y: h * 0.86))
            tri.closeSubpath()
            ctx.stroke(tri, with: .foreground, style: style)
            var star = Path()
            let c = CGPoint(x: w * 0.72, y: h * 0.72), r = w * 0.17
            star.move(to: CGPoint(x: c.x, y: c.y - r))
            star.addLine(to: CGPoint(x: c.x, y: c.y + r))
            star.move(to: CGPoint(x: c.x - r, y: c.y))
            star.addLine(to: CGPoint(x: c.x + r, y: c.y))
            ctx.stroke(star, with: .foreground, style: style)
        }
        .frame(width: 18, height: 18)
    }
}
