import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

/// Exporting: the layers picked, each on its own and only as big as it is, or the artboards they
/// lie on, or all of them; as pictures or SVGs, a file each, or as one PDF with a page each.
struct ExportSheet: View {
    let store: DocumentStore
    @AppStorage("exportFormat") private var format: ExportFormat = .png
    @AppStorage("exportScale") private var scale: Double = 2
    /// Slides are measured in the pixels the platforms take, so they go out at 1× unless asked otherwise.
    @AppStorage("carouselExportScale") private var slideScale: Double = 1
    @State private var scope: Scope?
    @State private var working = false
    @State private var done: URL?

    enum Scope: Hashable { case layers, artboards, all }

    /// The picked layers that are not artboards, each to be exported on its own.
    private var layers: [ExportItem] {
        store.selection.compactMap { id in ExportItem(layer: id, in: store.doc) }
    }

    /// The artboards the picked layers lie on, or that are picked themselves.
    private var pickedBoards: [Node] {
        let ids = Set(store.selection.map { store.doc.artboard(of: $0)?.id ?? $0 })
        return store.doc.artboards.filter { ids.contains($0.id) }
    }

    /// What can be chosen, the most particular first, which is what is chosen to begin with.
    private var scopes: [Scope] {
        var out: [Scope] = []
        if !layers.isEmpty { out.append(.layers) }
        let boards = pickedBoards.count
        if boards > 0 && (boards < store.doc.artboards.count || !layers.isEmpty) { out.append(.artboards) }
        // All of them, unless that is what the artboards picked already are.
        if boards < store.doc.artboards.count || out.isEmpty { out.append(.all) }
        return out
    }

    private var chosen: Scope { scope.flatMap { scopes.contains($0) ? $0 : nil } ?? scopes[0] }

    private var items: [ExportItem] {
        switch chosen {
        case .layers: layers
        case .artboards: pickedBoards.flatMap(ExportItem.items(for:))
        case .all: store.doc.artboards.flatMap(ExportItem.items(for:))
        }
    }

    /// Whether all that goes out is slides of carousels, which keep a scale of their own.
    private var onlySlides: Bool {
        let items = items
        return !items.isEmpty && items.allSatisfy { $0.slide != nil }
    }

    private var scaleUsed: Binding<Double> { onlySlides ? $slideScale : $scale }

    private func title(_ scope: Scope) -> String {
        switch scope {
        case .layers:
            let picked = layers
            if picked.count > 1 { return "\(picked.count) layers" }
            return picked.first?.node.isGroup == true ? "This group" : "This layer"
        case .artboards: return pickedBoards.count == 1 ? "Its artboard" : "\(pickedBoards.count) artboards"
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
                if store.doc.artboards.isEmpty && layers.isEmpty {
                    Text("There is nothing to export yet. Draw an artboard with A.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink2)
                } else {
                    let scopes = scopes
                    if scopes.count > 1 {
                        SegmentedWell(selection: Binding(get: { chosen }, set: { scope = $0 }), options: scopes.map { ($0, title($0)) })
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Format").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                        SegmentedWell(selection: $format, options: [(.png, "PNG"), (.jpeg, "JPEG"), (.svg, "SVG"), (.pdf, "PDF")])
                    }
                    if format.isPicture {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Scale").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                            SegmentedWell(selection: scaleUsed, options: [(1, "1×"), (2, "2×"), (3, "3×")])
                        }
                    }
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let done {
                        HStack(spacing: 6) {
                            CheckMark(size: 11, color: Theme.ink2)
                            Text("Saved in \(done.lastPathComponent).")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.ink2)
                            TextButton(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([done]) }
                        }
                        .transition(.opacity)
                    }
                    PrimaryButton(title: working ? "Exporting…" : "Export…", progress: working ? 0.6 : nil, enabled: !working && !items.isEmpty) { export() }
                }
            }
            .padding(24)
            .frame(width: 380)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5) }
            .shadow(color: Theme.shadow.opacity(0.22), radius: 30, y: 14)
            .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
        .onExitCommand { close() }
    }

    /// What goes out, in words: a carousel by its slides.
    private func names(_ items: [ExportItem]) -> String {
        guard let first = items.first else { return "" }
        if chosen == .layers { return items.count == 1 ? first.name : "\(items.count) layers" }
        let boards = Set(items.map(\.node.id)).count
        let carousels = Set(items.filter { $0.slide != nil }.map(\.node.id)).count
        if boards == 1 { return carousels == 1 ? "The \(items.count == 1 ? "one slide" : "\(items.count) slides") of \(first.node.name)" : first.name }
        return "\(boards) artboards" + (carousels == 0 ? "" : carousels == 1 ? ", the carousel a slide each" : ", the carousels a slide each")
    }

    private var summary: String {
        let items = items
        guard let first = items.first else { return "" }
        let one = items.count == 1
        let names = names(items)
        // A layer goes out only as big as what it paints, shadow and all, on nothing.
        let alone = chosen == .layers ? (format == .jpeg ? ", on white" : ", on a transparent background") : ""
        switch format {
        case .pdf:
            return "\(names) as one PDF\(one ? "" : ", a page each"), with text and shapes kept sharp at any size\(alone)."
        case .svg:
            return "\(names) as SVG\(one ? "" : ", a file each"): shapes, text and gradients stay editable; background blurs come as pictures\(alone)."
        case .png, .jpeg:
            var size = ""
            // One picture, or slides all the same size.
            let sizes = one ? [first.bounds(assets: store.assets).size] : chosen == .layers ? [] : items.map { $0.bounds(assets: nil).size }
            if let s = sizes.first, sizes.allSatisfy({ $0 == s }) {
                let scale = scaleUsed.wrappedValue
                size = " at \(Int((s.width * scale).rounded())) × \(Int((s.height * scale).rounded())) pixels"
            }
            return "\(names)\(size)\(one ? "" : ", a file each")\(alone)."
        }
    }

    private func close() { store.exporting = false }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where the exported files go."
        if let last = UserDefaults.standard.string(forKey: "exportFolder") { panel.directoryURL = URL(fileURLWithPath: last) }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        UserDefaults.standard.set(folder.path, forKey: "exportFolder")
        working = true
        let written = Exporter.export(items, format: format, scale: CGFloat(scaleUsed.wrappedValue), name: store.name, to: folder, assets: store.assets)
        working = false
        withAnimation(Theme.spring) { done = written.first.map { written.count == 1 ? $0 : folder } }
    }
}

enum ExportPanel {
    static func present(for store: DocumentStore) { store.exporting = true }
}
