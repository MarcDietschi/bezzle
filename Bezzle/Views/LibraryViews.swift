import SwiftUI
import AppKit

// MARK: - On the shelf

/// Another design on the resources shelf: a few of its components, and its colours along the foot.
struct DesignLibraryCover: View {
    let library: LibraryContent

    var body: some View {
        let masters = Array(library.ownMasters.prefix(3))
        let colours = library.ownStyles.compactMap { $0.look.paint }.prefix(8)
        ZStack {
            Theme.card
            VStack(spacing: 0) {
                if !masters.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(masters, id: \.id) { m in
                            if let image = LibraryPictures.image(of: m, in: library, size: CGSize(width: 46, height: 34)) {
                                Image(decorative: image, scale: 2)
                                    .resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: 46, maxHeight: 34)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(maxHeight: .infinity)
                }
                if !colours.isEmpty {
                    // As a fan deck's strips, side by side; taller when there is nothing else.
                    HStack(spacing: 0) {
                        ForEach(Array(colours.enumerated()), id: \.offset) { _, p in
                            FillSwatch(fill: Fill(color: p.color, gradient: p.gradient), radius: 0)
                        }
                    }
                    .frame(height: masters.isEmpty ? nil : 14)
                    .frame(maxHeight: masters.isEmpty ? .infinity : 14)
                }
            }
            if masters.isEmpty && colours.isEmpty, let style = library.ownStyles.first {
                LibraryStylePicture(look: style.look, size: 30)
            }
        }
    }
}

// MARK: - A design's page

/// Another design's components and styles, to take into this one: its styles first, as small
/// chips, a click giving one to the selection (or, with nothing selected, to the design); then its
/// components, a click or a drag putting a copy onto the canvas. What was taken from it and has
/// changed there since is offered at the top.
struct LibraryPage: View {
    let store: DocumentStore
    let url: URL
    let query: String

    var body: some View {
        let shelf = LibraryShelf.shared
        ScrollView {
            if let library = shelf.content(url) {
                let masters = library.ownMasters.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                let styles = library.ownStyles.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let news = shelf.news(for: store.doc, at: store.url).first(where: { $0.url == library.url }) {
                        NewsRow(store: store, news: news)
                            .transition(.opacity.combined(with: .offset(y: -6)))
                    }
                    if !styles.isEmpty {
                        LibraryStyles(store: store, library: library, styles: styles)
                    }
                    if !masters.isEmpty {
                        LibraryComponents(store: store, library: library, masters: masters)
                    }
                    if masters.isEmpty && styles.isEmpty { NothingFound() }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
                .animation(Theme.spring, value: shelf.news(for: store.doc, at: store.url).map(\.url))
            }
        }
        .scrollIndicators(.never)
        .edgeFade(length: 16)
    }
}

/// What changed in this library since the design took from it, on its page: the same offer as on
/// the canvas, for when that was set aside.
private struct NewsRow: View {
    let store: DocumentStore
    let news: LibraryNews

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: LibraryNewsChip.things(news, in: store))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink2)
                .lineLimit(2)
            Spacer(minLength: 4)
            UpdateButton(store: store, news: news)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.linked.opacity(0.08)) }
    }
}

/// Components of another design, two by two.
struct LibraryComponents: View {
    let store: DocumentStore
    let library: LibraryContent
    let masters: [Node]
    /// Whether the design's name heads them, among other things found.
    var showsDesign = false

    var body: some View {
        let width = (ResourcesPanel.inner - ResourcesPanel.gap) / 2
        VStack(alignment: .leading, spacing: 8) {
            if showsDesign {
                Text(verbatim: library.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
            }
            LazyVGrid(columns: [GridItem(.fixed(width), spacing: ResourcesPanel.gap), GridItem(.fixed(width), spacing: ResourcesPanel.gap)],
                      alignment: .leading, spacing: 12) {
                ForEach(masters, id: \.id) { m in
                    LibraryComponentTile(store: store, library: library, master: m, width: width)
                }
            }
        }
    }
}

/// One component of another design, drawn as a new copy of it would look: a click puts a copy onto
/// the artboard in view, a drag carries one onto the canvas. Taken already, it is this design's own
/// too, and marked so.
private struct LibraryComponentTile: View {
    let store: DocumentStore
    let library: LibraryContent
    let master: Node
    let width: CGFloat
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        let image = LibraryPictures.image(of: master, in: library, size: CGSize(width: width - 12, height: 64))
        let taken = store.doc.master(master.id) != nil
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
                DragSource(resource: .library(library.url, master.id), tip: master.name,
                           picture: { Thumbnails.picture(image, width: min(width * 0.9, 180)) },
                           hovering: $hovering, pressed: $pressed) {
                    store.place(.library(library.url, master.id))
                    if let canvas = store.canvas { canvas.window?.makeFirstResponder(canvas) }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if taken { ComponentGlyph(size: 9).foregroundStyle(Theme.linked) }
                Text(verbatim: master.name)
                    .foregroundStyle(hovering ? Theme.ink : Theme.ink2)
                    .lineLimit(1)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 2)
        }
        .frame(width: width, alignment: .leading)
        .animation(Theme.spring, value: hovering)
        .animation(Theme.quick, value: pressed)
    }
}

/// Styles of another design, by kind, two by two: what each looks like, and its name.
private struct LibraryStyles: View {
    let store: DocumentStore
    let library: LibraryContent
    let styles: [Style]

    var body: some View {
        let width = (ResourcesPanel.inner - ResourcesPanel.gap) / 2
        LazyVGrid(columns: [GridItem(.fixed(width), spacing: ResourcesPanel.gap), GridItem(.fixed(width), spacing: ResourcesPanel.gap)],
                  alignment: .leading, spacing: 6) {
            ForEach(styles) { style in
                LibraryStyleChip(store: store, library: library, style: style, width: width)
            }
        }
    }
}

/// One style of another design. Pointing at it shows it on the selection; a click gives it to the
/// selection, bringing it into this design, or with nothing selected only brings it in.
private struct LibraryStyleChip: View {
    let store: DocumentStore
    let library: LibraryContent
    let style: Style
    let width: CGFloat
    @State private var hovering = false

    var body: some View {
        let taken = store.doc.style(style.id) != nil
        HStack(spacing: 7) {
            LibraryStylePicture(look: style.look, size: 22)
                .scaleEffect(hovering ? 1.08 : 1)
            Text(verbatim: style.name)
                .font(.system(size: 11))
                .foregroundStyle(hovering ? Theme.ink : Theme.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if taken {
                Circle().fill(Theme.pencil).frame(width: 4, height: 4)
            }
        }
        .padding(.horizontal, 5)
        .frame(width: width, height: 32, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Theme.ink.opacity(0.05) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(Theme.pop) { hovering = inside }
            store.preview(inside ? style : nil)
        }
        .onTapGesture {
            store.preview(nil)
            withAnimation(Theme.pop) { store.use(style.id, of: library) }
        }
        .onDisappear { if hovering { store.preview(nil) } }
        .help(Text(verbatim: style.name))
        .accessibilityAddTraits(.isButton)
    }
}

/// What a style looks like, small: a colour as a chip, type in itself, a shadow under a card,
/// corners as one corner drawn.
struct LibraryStylePicture: View {
    let look: StyleLook
    let size: CGFloat

    var body: some View {
        switch look {
        case .colour(let p):
            FillSwatch(fill: Fill(color: p.color, gradient: p.gradient), radius: size * 0.3)
                .frame(width: size, height: size)
                .overlay { RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5) }
        case .text(let t):
            Text(verbatim: "Aa")
                .font(StyleFont.font(t, size: size * 0.62))
                .foregroundStyle(Theme.ink)
                .frame(width: size, height: size)
                .background { RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(Theme.well) }
        case .shadow(let s):
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white)
                .frame(width: size * 0.7, height: size * 0.58)
                .shadow(color: Color(nsColor: s.color.with(alpha: min(1, s.color.a * 3)).nsColor),
                        radius: min(max(0.8, s.blur / 4), 4), x: s.x / 4, y: min(max(s.y / 4, 1), 3))
                .frame(width: size, height: size)
        case .corners(let c):
            let r = min(c.radius / 2, size * 0.5)
            UnevenRoundedRectangle(topLeadingRadius: r, style: (c.smoothing ?? 0) > 0 ? .continuous : .circular)
                .trim(from: 0, to: 1)
                .stroke(Theme.ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: size * 0.7, height: size * 0.7)
                .offset(x: size * 0.12, y: size * 0.12)
                .frame(width: size, height: size)
                .clipped()
        }
    }
}

// MARK: - On the canvas

/// What changed in another design since this one took from it, offered at the top of the canvas
/// when the design opens or the other design is saved: what it is and a button. Pointing at the
/// button shows the design brought up to date, and outlines what would change; a click brings it
/// up to date, and the change runs through every copy and every layer it reaches. The × leaves it
/// as it is, until there is newer.
struct LibraryNewsChip: View {
    let store: DocumentStore
    @State private var shown = false

    var body: some View {
        let shelf = LibraryShelf.shared
        VStack(spacing: 0) {
            // Something to appear, so the other designs are read when this one opens.
            Color.clear.frame(width: 1, height: 1)
                .onAppear { shelf.refresh(except: store.url) }
                .onChange(of: Library.shared.entries) { shelf.refresh(except: store.url) }
            if !store.isReadOnly, !store.prototyping, store.versions.travel == nil, store.finder == nil,
               let news = shelf.news(for: store.doc, at: store.url).first {
                HStack(spacing: 8) {
                    ComponentGlyph(size: 10)
                        .foregroundStyle(Theme.linked)
                        .padding(.leading, 12)
                    Text(verbatim: Self.things(news, in: store))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    UpdateButton(store: store, news: news)
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.showPreview("libraryNews", reshaping: nil)
                            withAnimation(Theme.spring) { shelf.setAside(news, for: store.url) }
                        }
                        .help(Text("Not Now"))
                        .padding(.trailing, 4)
                }
                .frame(height: 30)
                .background {
                    Capsule().fill(Theme.card)
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                }
                .fixedSize()
                .padding(.top, 14)
                .id(news.url)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: shelf.news(for: store.doc, at: store.url).first?.url)
    }

    /// "New in “Design System”: Button, Primary +2"
    static func things(_ news: LibraryNews, in store: DocumentStore) -> String {
        let names = news.masters.compactMap { store.doc.master($0)?.name } + news.styles.compactMap { store.doc.style($0)?.name }
        var list = names.prefix(2).joined(separator: ", ")
        if names.count > 2 { list += " +\(names.count - 2)" }
        return String(localized: "New in “\(news.name)”: \(list)")
    }
}

/// Brings what changed in a library into the design; pointing at it shows how that would look.
private struct UpdateButton: View {
    let store: DocumentStore
    let news: LibraryNews
    @State private var hovering = false

    var body: some View {
        Text("Update")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background { Capsule().fill(Color(nsColor: hovering ? CanvasInk.linked.blended(withFraction: 0.15, of: .black) ?? CanvasInk.linked : CanvasInk.linked)) }
            .contentShape(Capsule())
            .onHover { inside in
                hovering = inside
                store.showPreview("libraryNews", reshaping: inside ? store.updating(from: news) : nil)
                store.styleShow.lit = inside ? store.layers(in: news) : []
            }
            .onTapGesture {
                store.styleShow.lit = []
                withAnimation(Theme.pop) { store.update(from: news) }
            }
            .onDisappear {
                if hovering {
                    store.showPreview("libraryNews", reshaping: nil)
                    store.styleShow.lit = []
                }
            }
    }
}

// MARK: - Pictures

/// Other designs' components drawn small, as new copies of them would look, with those designs'
/// own pictures; made once each time the design is saved.
@MainActor
enum LibraryPictures {
    private static var made: [String: CGImage] = [:]
    private static var assets: [URL: Assets] = [:]

    static func image(of master: Node, in library: LibraryContent, size: CGSize) -> CGImage? {
        let key = "\(library.url.path)|\(library.modified.timeIntervalSince1970)|\(master.id)|\(Int(size.width))x\(Int(size.height))"
        if let hit = made[key] { return hit }
        if made.count > 400 { made.removeAll() }
        var doc = BezzleDocument()
        doc.nodes = [Components.newCopy(of: master, at: .zero, masters: library.mastersByID)]
        doc.fitGroups()
        let pictures = assets[library.url] ?? Assets(design: library.url)
        assets[library.url] = pictures
        let image = Renderer.thumbnail(of: doc, size: size, scale: 2, assets: pictures)
        made[key] = image
        return image
    }
}
