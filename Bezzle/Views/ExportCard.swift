import SwiftUI
import AppKit

/// What the selected layers go out as whenever what is marked is exported: a row a file, each with
/// its size, what goes after the layer's name, and its format, and under them the files' names as
/// they will be. The + adds the next size up, 2× after 1×; Export… writes them now.
struct ExportCard: View {
    let store: DocumentStore
    let nodes: [Node]
    @State private var progress: Double?
    @State private var done: ExportPanel.Outcome?
    @State private var asking: ExportPanel.Clash?

    /// The first layer's, which the rows show and every change sets on all of them.
    private var presets: [ExportPreset] { nodes.first?.exports ?? [] }

    var body: some View {
        let presets = presets
        let same = nodes.allSatisfy { $0.exports == presets }
        AspectCard(aspect: .export, title: "Export", summary: same ? Self.summary(of: presets) : SelectionInspector.several,
                   remove: { store.updateSelection("Unmark for Export") { $0.exports = nil } }, removal: "Unmark for export") {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 11.5, weight: .medium))
                .offset(y: -1)
        } picks: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(presets.enumerated()), id: \.offset) { i, preset in
                    row(i, preset)
                        .transition(.unfold)
                }
                HStack(spacing: 6) {
                    let next = ExportPreset.next(after: presets)
                    IconButton(symbol: "plus", help: next.format.isPicture ? "Add \(next.size.shown)" : "Add a file", size: 24) {
                        withAnimation(Theme.unfold) { set("Add Export Size", presets + [next]) }
                    }
                    Spacer(minLength: 0)
                    ChipButton(title: progress != nil ? "Exporting…" : "Export…", height: 26) { export() }
                        .disabled(progress != nil || asking != nil)
                }
                let files = files
                if !files.isEmpty {
                    // Plain: a name such as Icon@2x.png would otherwise be read as an address and linked.
                    Text(verbatim: ExportPanel.listing(files, marked: false))
                        .prose(11)
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let asking {
                    ExportPanel.Ask(clash: asking) { replacing in run(asking, replacing: replacing) } cancel: { withAnimation(Theme.spring) { self.asking = nil } }
                        .transition(.opacity)
                } else if let done {
                    ExportPanel.Saved(outcome: done)
                        .transition(.opacity)
                }
            }
            .animation(Theme.unfold, value: presets.count)
            // What was asked about is no longer what would go out.
            .onChange(of: presets) { asking = nil }
            .onChange(of: store.selection) { asking = nil; done = nil }
        }
    }

    /// One file: how big, what goes after the name, and the format.
    private func row(_ i: Int, _ preset: ExportPreset) -> some View {
        HStack(spacing: 4) {
            EntryField(text: preset.format.isPicture ? preset.size.shown : "1×", placeholder: "1×",
                       help: "Pixels to a point, such as 2×, or a width or height in pixels, such as 512w or 64h") { typed in
                guard let size = ExportSize(typed) else { return nil }
                change(i, "Change Export Size") { $0.size = size }
                return size.shown
            }
            .frame(width: 50)
            .opacity(preset.format.isPicture ? 1 : 0.4)
            .allowsHitTesting(preset.format.isPicture)
            EntryField(text: preset.nameSuffix, placeholder: String(localized: "Suffix"),
                       help: "Goes after the layer's name, such as @2x. A / puts the file in a folder.") { typed in
                let own = ExportPreset(size: preset.size, format: preset.format).nameSuffix
                change(i, "Change Export Suffix") { $0.suffix = typed == own ? nil : typed }
                return typed
            }
            MenuButton(id: "export-format-\(i)", title: .verbatim(preset.format.title), width: 120, fills: true) {
                ExportFormat.offered.map { f in
                    MenuEntry.item(.verbatim(f.title), checked: f == preset.format) {
                        change(i, "Change Export Format") { $0.format = f }
                    }
                }
            }
            .frame(width: 70)
            IconButton(symbol: "minus", help: "Remove this file", size: 20) {
                var less = presets
                less.remove(at: i)
                withAnimation(Theme.unfold) { set(less.isEmpty ? "Unmark for Export" : "Remove Export Size", less) }
            }
        }
    }

    /// The files exporting the selection as it is marked would make.
    private var files: [ExportFile] {
        Exporter.files(presetsOf: ExportItem.items(for: store.selection, in: store.doc))
    }

    private func change(_ i: Int, _ action: LocalizedStringResource, _ edit: (inout ExportPreset) -> Void) {
        var all = presets
        guard all.indices.contains(i) else { return }
        edit(&all[i])
        set(action, all)
    }

    private func set(_ action: LocalizedStringResource, _ presets: [ExportPreset]) {
        store.updateSelection(action) { $0.exports = presets.isEmpty ? nil : presets }
    }

    private func export() {
        let files = files
        guard !files.isEmpty, let folder = ExportPanel.chooseFolder() else { return }
        let clash = ExportPanel.Clash(files: files, folder: folder)
        withAnimation(Theme.spring) { done = nil }
        if clash.taken.isEmpty { run(clash, replacing: false) } else { withAnimation(Theme.spring) { asking = clash } }
    }

    private func run(_ export: ExportPanel.Clash, replacing: Bool) {
        withAnimation(Theme.spring) { asking = nil }
        let quality = UserDefaults.standard.object(forKey: "exportQuality") as? Double ?? Exporter.defaultQuality
        ExportPanel.write(export.files, quality: quality, to: export.folder, replacing: replacing, assets: store.assets) { progress = $0 } finished: { outcome in
            withAnimation(Theme.spring) { done = outcome }
        }
    }

    /// The presets in a few words: each format once, with its sizes, "PNG 1× 2× 3× · SVG".
    static func summary(of presets: [ExportPreset]) -> String {
        var formats: [ExportFormat] = []
        var sizes: [ExportFormat: [String]] = [:]
        for p in presets {
            if sizes[p.format] == nil {
                formats.append(p.format)
                sizes[p.format] = []
            }
            if p.format.isPicture { sizes[p.format, default: []].append(p.size.shown) }
        }
        return formats.map { ([$0.title] + (sizes[$0] ?? [])).joined(separator: " ") }.joined(separator: " · ")
    }
}

/// A word or two in a well, typed into and kept on Return or a click elsewhere; Escape puts back
/// what was there. `commit` takes what was typed and says how it reads now, or nil to put back
/// what was there.
struct EntryField: View {
    let text: String
    let placeholder: String
    let help: LocalizedStringResource
    let commit: (String) -> String?
    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(Theme.ink)
            .focused($focused)
            .onSubmit { take() }
            .onExitCommand { draft = text; focused = false }
            .padding(.horizontal, 8)
            .frame(height: Theme.controlHeight)
            .well(radius: 7)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.ink.opacity(focused ? 0.35 : hovering ? 0.12 : 0), lineWidth: 1)
            }
            .onHover { hovering = $0 }
            .help(Text(help))
            .onAppear { draft = text }
            .onChange(of: text) { _, now in if !focused { draft = now } }
            .onChange(of: focused) { _, now in if !now { take() } }
            .animation(Theme.quick, value: focused)
            .animation(Theme.quick, value: hovering)
    }

    private func take() {
        let typed = draft.trimmingCharacters(in: .whitespaces)
        if typed == text { return }
        draft = commit(typed) ?? text
    }
}
