import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// Exporting, as the Mac's Export sheet (Views/ExportSheet.swift): a card 400 wide over the
/// window, which dims; the layers picked, the post in front, their artboards, everything marked,
/// or all the artboards; as pictures (at 1×, 2× or 3×) or as one PDF; how much of a picture is
/// kept; a sentence saying what goes out; then Export…, which asks where the files go. Files of
/// the same names already there are replaced or kept beside, as asked; once written, where they
/// went, with a way to see them.
@MainActor
final class ExportSheet {
    let layer = Grid()
    private let session: DesignSession
    private let card = Border()
    private let stack = StackPanel()
    private var scope: String?
    private var progress: Double?
    private var asking: (folder: URL, taken: [URL])?
    private var done: (shown: URL, written: Int, missed: Int)?
    var isOpen: Bool { layer.visibility == .visible }

    /// What was chosen last time, kept as the Mac keeps it.
    private var format: String {
        get { UserDefaults.standard.string(forKey: "exportFormat").flatMap { WindowsCore.exportFormats.contains($0) ? $0 : nil } ?? "png" }
        set { UserDefaults.standard.set(newValue, forKey: "exportFormat") }
    }
    private var scaleKey: String { WindowsCore.exportOnlySlides(chosen, selection: session.selection) ? "carouselExportScale" : "exportScale" }
    private var scale: Double {
        get { UserDefaults.standard.object(forKey: scaleKey) as? Double ?? (scaleKey == "exportScale" ? 2 : 1) }
        set { UserDefaults.standard.set(newValue, forKey: scaleKey) }
    }
    private var quality: Double {
        get { UserDefaults.standard.object(forKey: "exportQuality") as? Double ?? 0.9 }
        set { UserDefaults.standard.set(newValue, forKey: "exportQuality") }
    }

    private var scopes: [(key: String, title: String)] { WindowsCore.exportScopes(session.selection) }
    private var chosen: String { scope.flatMap { s in scopes.contains { $0.key == s } ? s : nil } ?? scopes.first?.key ?? "all" }

    init(session: DesignSession) {
        self.session = session
        layer.visibility = .collapsed
        layer.background = Theme.brush(0, 0.18)
        layer.pointerPressed.addHandler { [weak self] _, args in
            args?.handled = true
            self?.close()
        }
        card.width = 400
        card.cornerRadius = Theme.corners(18)
        card.background = Theme.brush(Theme.paper)
        card.borderBrush = Theme.hairline
        card.borderThickness = Theme.inset(0.5)
        card.horizontalAlignment = .center
        card.verticalAlignment = .center
        card.pointerPressed.addHandler { _, args in args?.handled = true }
        stack.spacing = 18
        stack.margin = Theme.inset(24)
        card.child = stack
        layer.children.append(card)
    }

    func open() {
        scope = nil
        asking = nil
        done = nil
        layer.visibility = .visible
        show()
    }

    func close() {
        guard progress == nil else { return }
        layer.visibility = .collapsed
    }

    private func show() {
        stack.children.clear()
        let head = Grid()
        let title = Theme.text("Export", size: 22, weight: 500, serif: true)
        head.children.append(title)
        let closer = Pressable(radius: 8) { [weak self] in self?.close() }
        closer.box.width = 26
        closer.box.height = 26
        closer.box.horizontalAlignment = .right
        closer.box.child = Glyphs.view(Glyphs.cross(size: 26), size: 26, brush: Theme.ink(2))
        head.children.append(closer.box)
        stack.children.append(head)

        let scopes = scopes
        guard !scopes.isEmpty else {
            let words = Theme.text("There is nothing to export yet. Draw an artboard with A.", size: 13, ink: 2)
            words.textWrapping = .wrap
            stack.children.append(words)
            return
        }
        let ids = session.selection, chosen = chosen
        if scopes.count > 1 {
            stack.children.append(Controls.segmented(chosen, scopes.map { ($0.key, $0.title) }) { [weak self] key in
                self?.scope = key
                self?.asking = nil
                self?.show()
            })
        }
        if chosen != "marked" {
            stack.children.append(section("Format", Controls.segmented(format, WindowsCore.exportFormats.map { ($0, WindowsCore.formatTitle($0)) }) { [weak self] f in
                self?.format = f
                self?.asking = nil
                self?.show()
            }))
            if WindowsCore.formatIsPicture(format) {
                stack.children.append(section("Scale", Controls.segmented(scale, [(1.0, "1×"), (2.0, "2×"), (3.0, "3×")]) { [weak self] s in
                    self?.scale = s
                    self?.asking = nil
                    self?.show()
                }))
            }
        }
        if WindowsCore.exportLossy(chosen, format: format, selection: ids) {
            stack.children.append(section("Quality", Controls.segmented(quality, WindowsCore.exportQualities(chosen, format: format)) { [weak self] q in
                self?.quality = q
                self?.show()
            }))
        }
        let summary = Theme.text(WindowsCore.exportSummary(chosen, format: format, scale: scale, selection: ids), size: 12, ink: 3)
        summary.textWrapping = .wrap
        summary.lineHeight = 17
        stack.children.append(summary)
        if let asking {
            stack.children.append(Self.ask(asking, replace: { [weak self] in self?.run(asking.folder, replacing: true) },
                                           keep: { [weak self] in self?.run(asking.folder, replacing: false) },
                                           cancel: { [weak self] in self?.asking = nil; self?.show() }))
        } else if let done {
            stack.children.append(Self.saved(done))
        }
        stack.children.append(primary(progress != nil ? "Exporting…" : "Export…", enabled: progress == nil && asking == nil) { [weak self] in self?.export() })
    }

    private func section(_ title: String, _ control: FrameworkElement) -> UIElement {
        let s = StackPanel()
        s.spacing = 8
        s.children.append(Theme.text(title, size: 12.5, weight: 600))
        s.children.append(control)
        return s
    }

    /// The Mac's PrimaryButton: 38 tall, radius 10, ink with the paper's colour on it, filling
    /// with pencil from the left as the work goes.
    private func primary(_ title: String, enabled: Bool, _ action: @escaping @MainActor () -> Void) -> UIElement {
        let press = Pressable(radius: 10) { if enabled { action() } }
        press.hoverWash = 0
        let box = Grid()
        box.height = 38
        let back = Border()
        back.cornerRadius = Theme.corners(10)
        back.background = Theme.brush(Theme.ink, enabled ? 1 : 0.22)
        box.children.append(back)
        if let progress {
            let fill = Border()
            fill.horizontalAlignment = .left
            fill.cornerRadius = Theme.corners(10)
            fill.background = Theme.brush(Theme.pencil)
            fill.width = max(14, 352 * progress)
            box.children.append(fill)
        }
        let label = Theme.text(title, size: 13, weight: 600)
        label.foreground = Theme.brush(Theme.paper, enabled ? 1 : 0.8)
        label.horizontalAlignment = .center
        label.verticalAlignment = .center
        box.children.append(label)
        press.box.child = box
        press.box.pointerEntered.addHandler { _, _ in if enabled { back.background = Theme.brush(Theme.ink, 0.88) } }
        press.box.pointerExited.addHandler { _, _ in if enabled { back.background = Theme.brush(Theme.ink) } }
        return press.box
    }

    /// The question before files of the same names are replaced: replace them, or keep both.
    static func ask(_ clash: (folder: URL, taken: [URL]), replace: @escaping @MainActor () -> Void, keep: @escaping @MainActor () -> Void,
                    cancel: @escaping @MainActor () -> Void) -> UIElement {
        let box = Border()
        box.cornerRadius = Theme.corners(10)
        box.background = Theme.brush(Theme.pencil, Theme.pencilWash)
        let s = StackPanel()
        s.spacing = 8
        s.margin = Theme.inset(10)
        let place = clash.folder.lastPathComponent
        let said = clash.taken.count == 1 ? "There is already a file named \(clash.taken[0].lastPathComponent) in \(place)."
            : "\(clash.taken.count) of the files are already in \(place)."
        let words = Theme.text(said, size: 12)
        words.textWrapping = .wrap
        s.children.append(words)
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 6
        row.children.append(chip("Replace", replace))
        row.children.append(chip("Keep Both", keep))
        row.children.append(textButton("Cancel", cancel))
        s.children.append(row)
        box.child = s
        return box
    }

    /// Where the files went, with a button to see them, and what could not be made.
    static func saved(_ outcome: (shown: URL, written: Int, missed: Int)) -> UIElement {
        let s = StackPanel()
        s.spacing = 4
        if outcome.written > 0 {
            let row = StackPanel()
            row.orientation = .horizontal
            row.spacing = 6
            let check = Glyphs.view(Glyphs.check(size: 11), size: 11, brush: Theme.ink(2))
            check.verticalAlignment = .center
            row.children.append(check)
            let words = Theme.text("Saved in \(outcome.shown.lastPathComponent).", size: 12, ink: 2)
            words.verticalAlignment = .center
            words.textTrimming = .characterEllipsis
            words.maxWidth = 220
            row.children.append(words)
            row.children.append(textButton("Show in Explorer") { Self.reveal(outcome.shown) })
            s.children.append(row)
        }
        if outcome.missed > 0 {
            let said = outcome.missed == 1 ? "One file could not be made." : "\(outcome.missed) files could not be made."
            let words = Theme.text(said, size: 12)
            words.foreground = Theme.brush(0xC2410C)
            words.textWrapping = .wrap
            s.children.append(words)
        }
        return s
    }

    static func chip(_ title: String, _ action: @escaping @MainActor () -> Void) -> UIElement {
        let press = Pressable(radius: 8, action: action)
        press.hoverWash = 0.06
        press.box.height = 26
        press.box.background = Theme.brush(Theme.card)
        press.box.borderBrush = Theme.hairline
        press.box.borderThickness = Theme.inset(0.5)
        let label = Theme.text(title, size: 12, weight: 500)
        label.margin = Theme.inset(10, 0, 10, 0)
        label.verticalAlignment = .center
        press.box.child = label
        return press.box
    }

    static func textButton(_ title: String, _ action: @escaping @MainActor () -> Void) -> UIElement {
        let press = Pressable(radius: 6, action: action)
        press.box.height = 26
        let label = Theme.text(title, size: 12, weight: 500)
        label.foreground = Theme.brush(Theme.pencil)
        label.margin = Theme.inset(8, 0, 8, 0)
        label.verticalAlignment = .center
        press.box.child = label
        return press.box
    }

    /// Asks where the files go, starting where the last ones went; asks again before replacing.
    private func export() {
        let last = UserDefaults.standard.string(forKey: "exportFolder").map { URL(fileURLWithPath: $0) }
        guard let folder = FileDialogs.chooseFolder(title: "Choose where the exported files go", button: "Export Here", startingIn: last) else { return }
        UserDefaults.standard.set(folder.path, forKey: "exportFolder")
        done = nil
        let taken = WindowsCore.exportClashes(chosen, format: format, scale: scale, selection: session.selection, in: folder)
        if taken.isEmpty { run(folder, replacing: false) } else { asking = (folder, taken); show() }
    }

    private func run(_ folder: URL, replacing: Bool) {
        asking = nil
        progress = 0
        show()
        let scope = chosen, format = format, scale = scale, quality = quality, ids = session.selection
        Task { @MainActor [weak self] in
            let outcome = await WindowsCore.export(scope, format: format, scale: scale, quality: quality, selection: ids,
                                                   to: folder, replacing: replacing) { [weak self] p in
                self?.progress = p
                self?.show()
            }
            guard let self else { return }
            self.progress = nil
            self.done = outcome
            self.show()
        }
    }

    /// Shows a file in Explorer, picked out, or opens a folder.
    static func reveal(_ url: URL) {
        var isFolder: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\explorer.exe")
        process.arguments = isFolder.boolValue ? [url.path] : ["/select,\(url.path)"]
        try? process.run()
    }
}
