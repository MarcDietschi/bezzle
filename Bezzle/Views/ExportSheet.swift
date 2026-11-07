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

    typealias Scope = ExportChoices.Scope

    /// What can go out from where the design stands (the shared `ExportChoices`).
    private var choices: ExportChoices {
        ExportChoices(doc: store.doc, seen: store.seenDoc, selection: store.selection, front: { store.front(of: $0) }, name: store.name)
    }

    private var scopes: [Scope] { choices.scopes }
    private var chosen: Scope { choices.chosen(scope) }
    private var items: [ExportItem] { choices.items(chosen) }
    private var layers: [ExportItem] { choices.layers }
    private var marked: [ExportItem] { choices.marked }

    /// The format used, which is PNG again if the one last used cannot be written on this Mac.
    private var formatUsed: ExportFormat { format.isAvailable ? format : .png }

    /// What the export will write.
    private var files: [ExportFile] { choices.files(chosen, format: formatUsed, scale: CGFloat(scaleUsed.wrappedValue)) }

    private var scaleUsed: Binding<Double> { choices.onlySlides(chosen) ? $slideScale : $scale }

    /// Whether how much of the picture is kept matters to what goes out.
    private var lossy: Bool { choices.lossy(chosen, format: formatUsed) }

    private func title(_ scope: Scope) -> LocalizedStringResource { choices.title(scope) }

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
                if choices.isEmpty {
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

    private var summary: String {
        let assets = store.assets, one = items.count == 1
        return choices.summary(chosen, format: formatUsed, scale: scaleUsed.wrappedValue) { $0.bounds(assets: one ? assets : nil).size }
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

    /// How much of a picture is kept, as offered (the shared `ExportChoices.qualities`).
    static func qualities(for format: ExportFormat?) -> [(Double, LocalizedStringResource)] { ExportChoices.qualities(for: format) }

    /// The files that will be written, by name (the shared `ExportChoices.listing`).
    static func listing(_ files: [ExportFile], marked: Bool = true) -> String { ExportChoices.listing(files, marked: marked) }

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
