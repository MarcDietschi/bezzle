import Foundation
import WinUI
import UWP
import BezzleCore

/// What the selected layers go out as whenever what is marked is exported, as the Mac's Export
/// card: a row a file, each with its size, what goes after the layer's name and its format, and
/// under them the files' names as they will be. The + adds the next size up, 2× after 1×;
/// Export… writes them now.
extension Inspector {
    func exportCard(_ ids: [UUID], board: Int) -> UIElement? {
        guard let marked = WindowsCore.exportMarks(ids) else { return nil }
        @MainActor func edited() { session.edited(board: board) }
        let summary = marked.same ? marked.summary : "Several"
        return card("Export", summary, glyph: Glyphs.export(), remove: { [self] in
            WindowsCore.unmarkForExport(ids)
            session.edited(board: board)
        }, removal: "Unmark for export", body: { [self] in
            var rows: [UIElement] = []
            for (k, mark) in marked.marks.enumerated() {
                let size = Controls.entry(mark.size, placeholder: "1×", width: 50, enabled: mark.isPicture) { typed in
                    guard WindowsCore.setExportSize(ids, at: k, typed) else { return nil }
                    edited()
                    return WindowsCore.exportMarks(ids)?.marks[k].size
                }
                let suffix = Controls.entry(mark.suffix, placeholder: "Suffix") { typed in
                    WindowsCore.setExportSuffix(ids, at: k, typed)
                    edited()
                    return typed
                }
                let format = Controls.menuButton(WindowsCore.formatTitle(mark.format), width: 70, menus: menus, menuWidth: 120, entries: {
                    WindowsCore.exportFormats.map { f in
                        .item(WindowsCore.formatTitle(f), checked: f == mark.format) {
                            WindowsCore.setExportFormat(ids, at: k, f)
                            edited()
                        }
                    }
                })
                let remove = Controls.iconButton(Glyphs.minus(), size: 20) { [weak self] in
                    WindowsCore.removeExportMark(ids, at: k)
                    if WindowsCore.exportMarked(ids) == false { self?.opened = nil }
                    edited()
                }
                rows.append(Controls.line([size, suffix, format, remove], spacing: 4))
            }
            let foot = Grid()
            let more = Controls.iconButton(Glyphs.plus(size: 14), size: 24) {
                WindowsCore.addExportMark(ids)
                edited()
            }
            more.horizontalAlignment = .left
            foot.children.append(more)
            let go = ExportSheet.chip(exporting != nil ? "Exporting…" : "Export…") { [weak self] in self?.exportMarked(ids) }
            (go as? FrameworkElement)?.horizontalAlignment = .right
            foot.children.append(go)
            rows.append(foot)
            let listing = WindowsCore.markedListing(ids)
            if !listing.isEmpty {
                let words = Theme.text(listing, size: 11, ink: 3)
                words.textWrapping = .wrap
                words.lineHeight = 16
                rows.append(words)
            }
            if let asking = exportAsking, asking.ids == ids {
                rows.append(ExportSheet.ask((asking.folder, asking.taken),
                                            replace: { [weak self] in self?.runMarked(ids, to: asking.folder, replacing: true) },
                                            keep: { [weak self] in self?.runMarked(ids, to: asking.folder, replacing: false) },
                                            cancel: { [weak self] in self?.exportAsking = nil; self?.show() }))
            } else if let done = exportDone, done.ids == ids {
                rows.append(ExportSheet.saved(done.outcome))
            }
            return rows
        })
    }

    /// Asks where the files go, as the Export sheet does, then writes them.
    private func exportMarked(_ ids: [UUID]) {
        guard exporting == nil else { return }
        let last = UserDefaults.standard.string(forKey: "exportFolder").map { URL(fileURLWithPath: $0) }
        guard let folder = FileDialogs.chooseFolder(title: "Choose where the exported files go", button: "Export Here", startingIn: last) else { return }
        UserDefaults.standard.set(folder.path, forKey: "exportFolder")
        exportDone = nil
        let taken = WindowsCore.markedClashes(ids, in: folder)
        if taken.isEmpty { runMarked(ids, to: folder, replacing: false) } else { exportAsking = (ids, folder, taken); show() }
    }

    private func runMarked(_ ids: [UUID], to folder: URL, replacing: Bool) {
        exportAsking = nil
        exporting = 0
        show()
        let quality = UserDefaults.standard.object(forKey: "exportQuality") as? Double ?? 0.9
        Task { @MainActor [weak self] in
            let outcome = await WindowsCore.exportMarked(ids, quality: quality, to: folder, replacing: replacing) { [weak self] p in self?.exporting = p }
            guard let self else { return }
            self.exporting = nil
            self.exportDone = (ids, outcome)
            self.show()
        }
    }
}
