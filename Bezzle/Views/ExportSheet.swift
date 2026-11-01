import SwiftUI
import AppKit

/// Exporting: the layers picked, each on its own and only as big as it is, or the artboards they
/// lie on, or all of them; as pictures or SVGs, a file each, or as one PDF with a page each. Or
/// everything marked for export, each as its Export card says.
struct ExportSheet: View {
    let store: DocumentStore
    @AppStorage("exportFormat") private var format: ExportFormat = .png
    @AppStorage("exportScale") private var scale: Double = 2
    /// Slides are measured in the pixels the platforms take, so they go out at 1× unless asked otherwise.
    @AppStorage("carouselExportScale") private var slideScale: Double = 1
    @AppStorage("exportQuality") private var quality: Double = Exporter.defaultQuality
    @State private var scope: Scope?
    /// How far an export has come, 0…1, while it runs.
    @State private var progress: Double?
    @State private var done: ExportPanel.Outcome?
    /// An export waiting to be told whether to replace the files of the same name already there.
    @State private var asking: ExportPanel.Clash?

    enum Scope: Hashable { case layers, post, artboards, marked, all }

    /// The picked layers that are not artboards, each to be exported on its own.
    private var layers: [ExportItem] {
        store.selection.compactMap { id in ExportItem(layer: id, in: store.doc) }
    }

    /// The artboards the picked layers lie on, or that are picked themselves.
    private var pickedBoards: [Node] {
        let ids = Set(store.selection.map { store.doc.artboard(of: $0)?.id ?? $0 })
        return store.doc.artboards.filter { ids.contains($0.id) }
    }

    /// The deck picked, alone, whose post in front can go out by itself.
    private var pickedDeck: Node? {
        let boards = pickedBoards
        return boards.count == 1 && boards[0].isDeck && boards[0].posts.count > 1 ? boards[0] : nil
    }

    /// Everything marked for export, as it is seen.
    private var marked: [ExportItem] { ExportItem.marked(in: store.doc, seen: store.seenDoc) }

    /// What can be chosen, the most particular first, which is what is chosen to begin with.
    private var scopes: [Scope] {
        var out: [Scope] = []
        if !layers.isEmpty { out.append(.layers) }
        if pickedDeck != nil { out.append(.post) }
        let boards = pickedBoards.count
        if boards > 0 && (boards < store.doc.artboards.count || !layers.isEmpty) { out.append(.artboards) }
        if !marked.isEmpty { out.append(.marked) }
        // All of them, unless that is what the artboards picked already are.
        if boards < store.doc.artboards.count || out.isEmpty { out.append(.all) }
        return out
    }

    private var chosen: Scope { scope.flatMap { scopes.contains($0) ? $0 : nil } ?? scopes[0] }

    private var items: [ExportItem] {
        switch chosen {
        case .layers: layers
        case .post: pickedDeck.map { ExportItem.items(for: $0, post: store.front(of: $0)) } ?? []
        case .artboards: pickedBoards.flatMap(ExportItem.items(for:))
        case .marked: marked
        case .all: store.doc.artboards.flatMap(ExportItem.items(for:))
        }
    }

    /// The format used, which is PNG again if the one last used cannot be written on this Mac.
    private var formatUsed: ExportFormat { format.isAvailable ? format : .png }

    /// What the export will write.
    private var files: [ExportFile] {
        chosen == .marked ? Exporter.files(presetsOf: items)
            : Exporter.files(items, format: formatUsed, scale: CGFloat(scaleUsed.wrappedValue), name: store.name)
    }

    /// Whether all that goes out is slides of carousels, which keep a scale of their own.
    private var onlySlides: Bool {
        let items = items
        return !items.isEmpty && items.allSatisfy { $0.slide != nil }
    }

    private var scaleUsed: Binding<Double> { onlySlides ? $slideScale : $scale }

    /// Whether how much of the picture is kept matters to what goes out.
    private var lossy: Bool {
        chosen == .marked ? files.contains { $0.format.isLossy } : formatUsed.isLossy
    }

    private func title(_ scope: Scope) -> LocalizedStringResource {
        switch scope {
        case .layers:
            let picked = layers
            if picked.count > 1 { return "\(picked.count) layers" }
            return picked.first?.node.isGroup == true ? "This group" : "This layer"
        case .post: return "This post"
        case .artboards:
            if let deck = pickedDeck {
                // A narrow choice beside the others, so it may say less than the deck's own offer does.
                return LocalizedStringResource("export.all-posts", defaultValue: "All \(deck.posts.count) posts", comment: "Export choice: every post of the deck.")
            }
            return pickedBoards.count == 1 ? "Its artboard" : "\(pickedBoards.count) artboards"
        case .marked:
            return LocalizedStringResource("export.marked", defaultValue: "\(Set(marked.map(\.node.id)).count) marked",
                                           comment: "Export choice: every layer and artboard marked for export, each as its Export card says.")
        case .all: return "All \(store.doc.artboards.count)"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Export")
                        .font(Theme.serif(22, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    IconButton(symbol: "xmark", help: "Close") { close() }
                }
                if store.doc.artboards.isEmpty && layers.isEmpty && marked.isEmpty {
                    Text("There is nothing to export yet. Draw an artboard with A.")
                        .prose(13)
                        .foregroundStyle(Theme.ink2)
                } else {
                    let scopes = scopes
                    if scopes.count > 1 {
                        SegmentedWell(selection: Binding(get: { chosen }, set: { scope = $0 }), options: scopes.map { ($0, title($0)) })
                    }
                    if chosen != .marked {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Format").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                            SegmentedWell(selection: Binding(get: { formatUsed }, set: { format = $0 }),
                                          options: ExportFormat.offered.map { ($0, .verbatim($0.title)) })
                        }
                        if formatUsed.isPicture {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Scale").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                                SegmentedWell(selection: scaleUsed, options: [(1, .verbatim("1×")), (2, .verbatim("2×")), (3, .verbatim("3×"))])
                            }
                        }
                    }
                    if lossy {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Quality").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                            SegmentedWell(selection: $quality, options: ExportPanel.qualities(for: chosen == .marked ? nil : formatUsed))
                        }
                    }
                    Text(summary)
                        .prose(12)
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let asking {
                        ExportPanel.Ask(clash: asking) { replacing in run(asking, replacing: replacing) } cancel: { withAnimation(Theme.spring) { self.asking = nil } }
                            .transition(.opacity)
                    } else if let done {
                        ExportPanel.Saved(outcome: done)
                            .transition(.opacity)
                    }
                    PrimaryButton(title: progress != nil ? "Exporting…" : "Export…", progress: progress,
                                  enabled: progress == nil && asking == nil && !files.isEmpty) { export() }
                }
            }
            .padding(24)
            .frame(width: 400)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5) }
            .shadow(color: Theme.shadow.opacity(0.22), radius: 30, y: 14)
            .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
        .onExitCommand { close() }
        // What was asked about is no longer what would go out.
        .onChange(of: chosen) { asking = nil }
        .onChange(of: format) { asking = nil }
        .onChange(of: scale) { asking = nil }
        .onChange(of: slideScale) { asking = nil }
        .onChange(of: quality) { asking = nil }
    }

    /// What goes out, in words: a carousel by its slides, a deck by its posts.
    private func names(_ items: [ExportItem]) -> String {
        guard let first = items.first else { return "" }
        if chosen == .layers { return items.count == 1 ? first.name : String(localized: "\(items.count) layers") }
        if chosen == .post { return items.count == 1 ? first.name : String(localized: "The \(items.count) slides of \(first.name)") }
        let boards = Set(items.map(\.node.id)).count
        let carousels = Set(items.filter { $0.slide != nil }.map(\.node.id)).count
        let decks = Set(items.filter { $0.post != nil }.map(\.node.id)).count
        let name = first.node.name
        if boards == 1, decks == 1, let posts = first.post?.count {
            return switch (posts == 1, carousels == 1) {
            case (true, false): String(localized: "The one post of \(name)")
            case (true, true): String(localized: "The one post of \(name), a slide each")
            case (false, false): String(localized: "The \(posts) posts of \(name)")
            case (false, true): String(localized: "The \(posts) posts of \(name), a slide each")
            }
        }
        if boards == 1 {
            guard carousels == 1 else { return first.name }
            return items.count == 1 ? String(localized: "The one slide of \(name)") : String(localized: "The \(items.count) slides of \(name)")
        }
        var parts = [String(localized: "\(boards) artboards")]
        if decks > 0 { parts.append(decks == 1 ? String(localized: "the deck a post each") : String(localized: "the decks a post each")) }
        if carousels > 0 { parts.append(carousels == 1 ? String(localized: "the carousel a slide each") : String(localized: "the carousels a slide each")) }
        return parts.joined(separator: ", ")
    }

    private var summary: String {
        let items = items
        guard let first = items.first else { return "" }
        if chosen == .marked { return ExportPanel.listing(files) }
        let one = items.count == 1
        let names = names(items)
        // A layer goes out only as big as what it paints, shadow and all, on nothing.
        let alone = chosen == .layers ? (formatUsed.keepsTransparency ? String(localized: "on a transparent background") : String(localized: "on white")) : nil
        // Each part of the sentence is whole in itself, so it reads in any language once joined.
        var parts: [String?]
        switch formatUsed {
        case .pdf:
            parts = [String(localized: "\(names) as one PDF"), one ? nil : String(localized: "a page each"),
                     String(localized: "with text and shapes kept sharp at any size"), alone]
        case .svg:
            let lead = one ? String(localized: "\(names) as SVG") : String(localized: "\(names) as SVG, a file each")
            parts = [String(localized: "\(lead): shapes, text and gradients stay editable; background blurs come as pictures"), alone]
        case .png, .jpeg, .webp, .avif:
            var lead = names
            // One picture, or slides all the same size.
            let sizes = one ? [first.bounds(assets: store.assets).size] : chosen == .layers ? [] : items.map { $0.bounds(assets: nil).size }
            if let s = sizes.first, sizes.allSatisfy({ $0 == s }) {
                let scale = scaleUsed.wrappedValue
                lead = String(localized: "\(names) at \(Int((s.width * scale).rounded())) × \(Int((s.height * scale).rounded())) pixels")
            }
            parts = [lead, one ? nil : String(localized: "a file each"), alone]
        }
        return parts.compactMap { $0 }.joined(separator: ", ") + "."
    }

    private func close() { store.exporting = false }

    private func export() {
        guard let folder = ExportPanel.chooseFolder() else { return }
        let clash = ExportPanel.Clash(files: files, folder: folder)
        withAnimation(Theme.spring) { done = nil }
        if clash.taken.isEmpty { run(clash, replacing: false) } else { withAnimation(Theme.spring) { asking = clash } }
    }

    private func run(_ export: ExportPanel.Clash, replacing: Bool) {
        withAnimation(Theme.spring) { asking = nil }
        ExportPanel.write(export.files, quality: quality, to: export.folder, replacing: replacing, assets: store.assets) { progress = $0 } finished: { outcome in
            withAnimation(Theme.spring) { done = outcome }
        }
    }
}

/// What the Export sheet and the Export card share: where the files go, how they are written,
/// and what is said about them.
enum ExportPanel {
    static func present(for store: DocumentStore) { store.exporting = true }

    /// What an export came to: where its files are, and how many could not be made.
    struct Outcome: Equatable {
        /// The one file written, or the folder they went into.
        let shown: URL
        let written: Int
        let missed: Int
        /// Whether those not made are all WebPs, which cannot be as large as the others.
        var missedWebP = false
    }

    /// Asks where the files go, starting where the last ones went.
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export Here")
        panel.message = String(localized: "Choose where the exported files go.")
        if let last = UserDefaults.standard.string(forKey: "exportFolder") { panel.directoryURL = URL(fileURLWithPath: last) }
        guard panel.runModal() == .OK, let folder = panel.url else { return nil }
        UserDefaults.standard.set(folder.path, forKey: "exportFolder")
        // So that the AI's exports can go there too, after a restart.
        FileAccess.keep(folder)
        return folder
    }

    /// An export about to be written, and the files of the same names already where it goes.
    struct Clash: Equatable {
        let files: [ExportFile]
        let folder: URL
        let taken: [URL]

        init(files: [ExportFile], folder: URL) {
            self.files = files
            self.folder = folder
            taken = Exporter.clashes(files, in: folder)
        }

        static func == (a: Clash, b: Clash) -> Bool { a.folder == b.folder && a.taken == b.taken && a.files.map(\.name) == b.files.map(\.name) }
    }

    /// Writes the files a file at a time beside the canvas, telling how far it has come, and then
    /// what it came to. Files of the same names already there are replaced when `replacing`, and
    /// otherwise kept, the new ones getting a number.
    static func write(_ files: [ExportFile], quality: Double, to folder: URL, replacing: Bool, assets: Assets?,
                      progress: @escaping @MainActor (Double?) -> Void, finished: @escaping @MainActor (Outcome) -> Void) {
        progress(0)
        let places = Exporter.destinations(of: files, in: folder, replacing: replacing)
        Task {
            var written: [URL] = []
            var missed: [ExportFile] = []
            for (i, (file, place)) in zip(files, places).enumerated() {
                let made = await Task.detached(priority: .userInitiated) {
                    place.map { Exporter.write(file, to: $0, quality: quality, assets: assets) } ?? false
                }.value
                if made, let place { written.append(place) } else { missed.append(file) }
                progress(Double(i + 1) / Double(max(files.count, 1)))
            }
            progress(nil)
            finished(Outcome(shown: written.count == 1 ? written[0] : folder, written: written.count, missed: missed.count,
                             missedWebP: !missed.isEmpty && missed.allSatisfy { $0.format == .webp }))
        }
    }

    /// How much of a picture is kept, as offered: WebP's top is lossless, and with no format given,
    /// the top is each format's best.
    static func qualities(for format: ExportFormat?) -> [(Double, LocalizedStringResource)] {
        let top: LocalizedStringResource = format == .webp ? "Lossless" : format == nil ? "Best" : .verbatim("100%")
        return [(0.6, .verbatim("60%")), (0.8, .verbatim("80%")), (0.9, .verbatim("90%")), (1, top)]
    }

    /// The files that will be written, by name: the first few, and how many more; said to be as
    /// marked, in the Export sheet, where other choices lie beside it.
    static func listing(_ files: [ExportFile], marked: Bool = true) -> String {
        let names = files.map { "\($0.name).\($0.format.fileExtension)" }
        guard !names.isEmpty else { return "" }
        let few = names.count <= 4
        let list = few ? names.formatted(.list(type: .and)) : names.prefix(3).joined(separator: ", ")
        let more = names.count - 3
        return switch (marked, few) {
        case (true, true): String(localized: "As marked: \(list).")
        case (true, false): String(localized: "As marked: \(list) and \(more) more.")
        case (false, true): list
        case (false, false): String(localized: "\(list) and \(more) more")
        }
    }

    /// The question before files of the same names are replaced: replace them, or keep both,
    /// the new ones numbered.
    struct Ask: View {
        let clash: Clash
        let answer: (Bool) -> Void
        let cancel: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                let place = clash.folder.lastPathComponent
                let said: LocalizedStringResource = clash.taken.count == 1 ? "There is already a file named \(clash.taken[0].lastPathComponent) in \(place)."
                                                                           : "\(clash.taken.count) of the files are already in \(place)."
                // Plain, as a file name such as Icon@2x.png would otherwise be linked as an address.
                Text(verbatim: String(localized: said))
                    .prose(12)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                // On one line where there is room, as in the Export sheet; on the narrow card, the
                // choices first and the way back below them.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        choices
                        Spacer(minLength: 0)
                        TextButton(title: "Cancel") { cancel() }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) { choices }
                        TextButton(title: "Cancel") { cancel() }
                            .padding(.leading, -8)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        choices
                        TextButton(title: "Cancel") { cancel() }
                            .padding(.leading, -8)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.pencilWash))
            .help(Text("Keep Both gives the new files a number, such as Card 2.png."))
        }

        @ViewBuilder private var choices: some View {
            ChipButton(title: "Replace", height: 26) { answer(true) }
            ChipButton(title: "Keep Both", height: 26) { answer(false) }
        }
    }

    /// Where the files went, with a button to see them, and what could not be made.
    struct Saved: View {
        let outcome: Outcome

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                if outcome.written > 0 {
                    HStack(spacing: 6) {
                        CheckMark(size: 11, color: Theme.ink2)
                        Text(verbatim: String(localized: "Saved in \(outcome.shown.lastPathComponent)."))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        TextButton(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([outcome.shown]) }
                    }
                }
                if outcome.missed > 0 {
                    let said: LocalizedStringResource = outcome.missed == 1 ? "One file could not be made." : "\(outcome.missed) files could not be made."
                    Text(verbatim: String(localized: said) + (outcome.missedWebP ? " " + String(localized: "A WebP is at most 16383 pixels a side.") : ""))
                        .prose(12)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
