import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

// Sharing in the window and on home, as the Mac's Views/ShareButton.swift (ShareButton,
// Uploading, ProgressRing, SharingTag), the mark on a design's tab (TabBar's TabButton) and on
// its card on home (HomeView's DesignNote), and the questions the Mac asks with NSAlert (stopping
// a share, sending a shared design to the Recycle Bin, a share that could not be made).

// MARK: - Words

/// How a design is shared, in words, as the Mac's SharingMark gives them.
@MainActor
enum ShareWords {
    static func title(_ mark: WindowsCore.ShareMark) -> String {
        switch mark {
        case .shared: Words.t("Shared")
        case .sharedBy(let owner?): Words.t("Shared by %@", owner)
        case .sharedBy(nil): Words.t("Shared with you")
        case .ended: Words.t("No longer shared")
        case .inFolder(let service): Words.t("Shared in %@", service)
        }
    }

    /// What it means, for tooltips.
    static func help(_ mark: WindowsCore.ShareMark) -> String {
        switch mark {
        case .ended: Words.t("Read only: this design is no longer shared with you. Save a copy to keep working on it.")
        case .inFolder(let service): Words.t("Shared through %@: everyone’s changes come in as they are made", service)
        default: Words.t("Shared by link: everyone’s changes come in as they are made")
        }
    }

    /// The mark's little picture: a lock once it is no longer shared, else two people.
    static func glyph(_ mark: WindowsCore.ShareMark, size: Double) -> FrameworkElement {
        let ended = mark == .ended
        let parts = ended ? Glyphs.lock(locked: true, size: size) : Glyphs.share(size: size)
        let view = Glyphs.view(parts, size: size, brush: ended ? Theme.ink(3) : Theme.brush(Theme.pencil))
        view.verticalAlignment = .center
        return view
    }
}

// MARK: - Pictures

extension Glyphs {
    /// Someone in a circle, with a plus beside: the Mac's person.crop.circle.badge.plus, in
    /// Bezzle's own hand.
    static func invite(size s: Double = 12) -> [Part] {
        var ring = PathData(), head = PathData(), body = PathData(), plus = PathData()
        // The circle, open where the plus sits.
        let cx = s * 0.44, cy = s * 0.47, r = s * 0.38
        let from = 0.45 * Double.pi, to = 2.08 * Double.pi
        ring.move(cx + r * cos(from), cy + r * sin(from))
        for k in 1...24 {
            let a = from + (to - from) * Double(k) / 24
            ring.line(cx + r * cos(a), cy + r * sin(a))
        }
        head.ellipse(s * 0.32, s * 0.22, s * 0.24, s * 0.24)
        body.move(s * 0.2, s * 0.74)
        body.cubic(s * 0.25, s * 0.54, s * 0.63, s * 0.54, s * 0.68, s * 0.74)
        plus.move(s * 0.82, s * 0.62); plus.line(s * 0.82, s * 0.96)
        plus.move(s * 0.65, s * 0.79); plus.line(s * 0.99, s * 0.79)
        return [Part(data: ring.d, mode: .stroke, width: 1.1), Part(data: head.d, mode: .fill),
                Part(data: body.d, mode: .stroke, width: 1.2), Part(data: plus.d, mode: .stroke, width: 1.2)]
    }

    /// Two people, outlined, one behind the other: the Mac's person.2.
    static func people(size s: Double = 12) -> [Part] {
        var back = PathData(), front = PathData()
        back.ellipse(s * 0.58, s * 0.14, s * 0.28, s * 0.28)
        back.move(s * 0.66, s * 0.56); back.cubic(s * 0.82, s * 0.5, s * 0.97, s * 0.62, s * 0.98, s * 0.84)
        front.ellipse(s * 0.14, s * 0.2, s * 0.32, s * 0.32)
        front.move(s * 0.04, s * 0.92); front.cubic(s * 0.08, s * 0.62, s * 0.56, s * 0.62, s * 0.6, s * 0.92); front.close()
        return [Part(data: back.d, mode: .stroke, width: 1.1), Part(data: front.d, mode: .stroke, width: 1.1)]
    }

    /// A warning: a triangle with a mark in it, the Mac's exclamationmark.triangle.
    static func warning(size s: Double = 12) -> [Part] {
        var triangle = PathData(), bang = PathData(), dot = PathData()
        triangle.move(s * 0.5, s * 0.1); triangle.line(s * 0.95, s * 0.88); triangle.line(s * 0.05, s * 0.88); triangle.close()
        bang.move(s * 0.5, s * 0.38); bang.line(s * 0.5, s * 0.6)
        dot.ellipse(s * 0.45, s * 0.68, s * 0.1, s * 0.1)
        return [Part(data: triangle.d, mode: .stroke, width: 1.1), Part(data: bang.d, mode: .stroke, width: 1.3), Part(data: dot.d, mode: .fill)]
    }

    /// One sheet over another, the Mac's doc.on.doc: a copy.
    static func copies(size s: Double = 12) -> [Part] {
        var back = PathData(), front = PathData()
        // What shows of the sheet behind, past the one in front.
        back.move(s * 0.34, s * 0.26); back.line(s * 0.34, s * 0.14); back.quad(s * 0.34, s * 0.06, s * 0.42, s * 0.06)
        back.line(s * 0.82, s * 0.06); back.quad(s * 0.9, s * 0.06, s * 0.9, s * 0.14)
        back.line(s * 0.9, s * 0.62); back.quad(s * 0.9, s * 0.7, s * 0.82, s * 0.7); back.line(s * 0.7, s * 0.7)
        front.rect(s * 0.12, s * 0.28, s * 0.56, s * 0.66, radius: s * 0.09)
        return [Part(data: back.d, mode: .stroke, width: 1.1), Part(data: front.d, mode: .stroke, width: 1.1)]
    }
}

// MARK: - The ring while the design goes up

/// A ring drawn in pencil as far as `fraction` goes, or a short arc going round while it is not
/// known, as the Mac's ProgressRing.
@MainActor
final class ProgressRing {
    let root = Grid()
    private let arc = Canvas()
    private let turn = CompositeTransform()
    private var ticking: EventCleanup?
    private var began = 0.0
    private var fraction: Double?
    private let size: Double

    init(size: Double = 11) {
        self.size = size
        root.width = size
        root.height = size
        root.isHitTestVisible = false
        let ring = Ellipse()
        ring.width = size
        ring.height = size
        ring.stroke = Theme.ink(4)
        ring.strokeThickness = 1.6
        root.children.append(ring)
        arc.width = size
        arc.height = size
        turn.centerX = size / 2
        turn.centerY = size / 2
        arc.renderTransform = turn
        root.children.append(arc)
        set(nil)
        root.unloaded.addHandler { [weak self] _, _ in self?.stop() }
    }

    func set(_ fraction: Double?) {
        self.fraction = fraction
        draw(fraction.map { max(0.04, min($0, 1)) } ?? 0.28)
        if fraction == nil { start() } else { stop(); turn.rotation = 0 }
    }

    private func draw(_ f: Double) {
        arc.children.clear()
        let r = size / 2 - 0.8, c = size / 2
        var p = PathData()
        let steps = max(2, Int(f * 40))
        for k in 0...steps {
            let a = -Double.pi / 2 + 2 * Double.pi * f * Double(k) / Double(steps)
            if k == 0 { p.move(c + r * cos(a), c + r * sin(a)) } else { p.line(c + r * cos(a), c + r * sin(a)) }
        }
        let view = Glyphs.view([Glyphs.Part(data: p.d, mode: .stroke, width: 1.6)], size: size, brush: Theme.brush(Theme.pencil))
        arc.children.append(view)
    }

    private func start() {
        guard ticking == nil else { return }
        began = WindowsCore.now
        ticking = CompositionTarget.rendering.addHandler { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Once round in 0.9 s, as the Mac's.
                self.turn.rotation = ((WindowsCore.now - self.began) / 0.9).truncatingRemainder(dividingBy: 1) * 360
            }
        }
    }

    private func stop() {
        ticking?.dispose()
        ticking = nil
    }
}

// MARK: - In the bar

/// The design's sharing in the bar: how it is shared beside the zoom (the Mac's SharingTag), and
/// the Share… button with its menu, Copy Link and Stop Sharing… (the Mac's ShareButton). Before
/// a link is copied everything in the design goes up, and the button counts the pictures as they
/// go. Someone else's design no longer shared offers Save a Copy instead.
@MainActor
final class ShareControls {
    /// How it is shared, or, with others in its live room, who they are.
    let tag = Grid()
    /// Share…, its upload, or Save a Copy.
    let button = Grid()
    /// The mark before the design's name on its tab.
    let tabMark = Border()
    var menus: MenuHost?
    var questions: Questions?
    /// Who else is in the design this moment, shown in the tag's place while there is anyone.
    var people: FrameworkElement? { didSet { shown = "" } }
    private let session: DesignSession
    private var copied = false
    private var preparing = false
    private var upload: (done: Int, total: Int)?
    private var shown = ""
    private var ring: ProgressRing?
    private var uploadLabel: TextBlock?

    init(session: DesignSession) {
        self.session = session
        tag.verticalAlignment = .center
        button.verticalAlignment = .center
        tabMark.verticalAlignment = .center
        tabMark.background = Theme.clear
        refresh()
    }

    /// Shows the share as it is now.
    func refresh() {
        let mark = WindowsCore.shareMark, readOnly = WindowsCore.isReadOnly, problem = WindowsCore.shareProblem
        let key = [mark.map { "\($0)" } ?? "-", "\(readOnly)", problem ?? "", "\(copied)", "\(preparing)", "\(people != nil)"].joined(separator: "|")
        if key != shown {
            shown = key
            showButton(mark, readOnly: readOnly, problem: problem)
            showTag(mark)
            showTabMark(mark)
        }
        if preparing { showUpload() }
    }

    private func showButton(_ mark: WindowsCore.ShareMark?, readOnly: Bool, problem: String?) {
        button.children.clear()
        ring = nil
        uploadLabel = nil
        if readOnly {
            let save = Controls.cardButton(Words.t("Save a Copy"), glyph: Glyphs.copies(), height: 28) { [weak self] in self?.session.onSaveCopy?() }
            try? ToolTipService.setToolTip(save, Words.t("Make a design of your own from this one  Ctrl+Shift+S"))
            button.children.append(save)
            return
        }
        guard WindowsCore.canShare else { return }
        if preparing {
            // A ring filling as the pictures go, and how many.
            let card = Theme.card(radius: 28 * 0.28)
            card.height = 28
            let row = StackPanel()
            row.orientation = .horizontal
            row.spacing = 7
            row.margin = Theme.inset(14, 0, 14, 0)
            row.verticalAlignment = .center
            let ring = ProgressRing()
            ring.root.verticalAlignment = .center
            row.children.append(ring.root)
            let label = Theme.text("", size: 12.5, weight: 500, ink: 2)
            label.verticalAlignment = .center
            row.children.append(label)
            card.child = row
            try? ToolTipService.setToolTip(card, Words.t("Everything in the design goes up before the link is copied"))
            button.children.append(card)
            self.ring = ring
            uploadLabel = label
            showUpload()
            return
        }
        let glyph = copied ? Glyphs.check(size: 12) : mark == nil ? Glyphs.invite() : problem != nil ? Glyphs.warning() : Glyphs.people()
        let share = Controls.cardButton(Words.t(mark == nil ? "Share…" : "Shared"), glyph: glyph, height: 28) { [weak self] in self?.openMenu() }
        let help = copied ? Words.t("The link is copied: paste it into any mail or chat")
            : problem ?? mark.map(ShareWords.help) ?? Words.t("Work on this design together with others, by link")
        try? ToolTipService.setToolTip(share, help)
        button.children.append(share)
    }

    private func showUpload() {
        guard let ring, let uploadLabel else { return }
        let total = upload?.total ?? 0, done = upload?.done ?? 0
        ring.set(total > 0 ? Double(done) / Double(total) : nil)
        uploadLabel.text = total > 0 ? Words.t("Uploading %lld of %lld", done, total) : Words.t("Preparing…")
    }

    /// How it is shared, as a capsule beside the zoom: two people in the pencil's blue on its
    /// wash, or a lock in grey once someone else's design is no longer shared.
    private func showTag(_ mark: WindowsCore.ShareMark?) {
        tag.children.clear()
        if let people {
            tag.children.append(people)
            return
        }
        guard let mark else { return }
        let ended = mark == .ended
        let capsule = Border()
        capsule.height = 20
        capsule.cornerRadius = Theme.corners(10)
        capsule.background = ended ? Theme.brush(Theme.ink, 0.06) : Theme.brush(Theme.pencil, Theme.pencilWash)
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 5
        row.margin = Theme.inset(8, 0, 8, 0)
        row.verticalAlignment = .center
        row.children.append(ShareWords.glyph(mark, size: 10))
        let words = Theme.text(ShareWords.title(mark), size: 11.5, weight: 500)
        words.foreground = ended ? Theme.ink(3) : Theme.brush(Theme.pencil)
        words.verticalAlignment = .center
        words.maxWidth = 220
        words.textTrimming = .characterEllipsis
        row.children.append(words)
        capsule.child = row
        try? ToolTipService.setToolTip(capsule, ShareWords.help(mark))
        tag.children.append(capsule)
    }

    private func showTabMark(_ mark: WindowsCore.ShareMark?) {
        tabMark.child = mark.map { ShareWords.glyph($0, size: 9) }
        tabMark.margin = Theme.inset(12, 0, mark == nil ? 0 : 5, 0)
        if let mark { try? ToolTipService.setToolTip(tabMark, ShareWords.help(mark)) }
    }

    private func openMenu() {
        guard let menus, let anchor = button.children.first as? FrameworkElement else { return }
        if menus.isOpen { menus.close(); return }
        var entries: [MenuHost.Entry] = [
            .item("Copy Link") { [weak self] in self?.copyLink() },
            .note("Anyone with the link can work on the design."),
        ]
        if WindowsCore.shareMark == .shared {
            entries += [.separator, .item("Stop Sharing…") { [weak self] in self?.confirmStop() }]
        }
        menus.show(below: anchor, width: 260, entries: entries)
    }

    /// Shares the design if it is not yet, once everything in it is on the relay, and puts its
    /// link on the clipboard (the Mac's Sharing.copyLink).
    private func copyLink() {
        guard !preparing else { return }
        preparing = true
        upload = nil
        refresh()
        let name = session.name
        Task { @MainActor [weak self] in
            do {
                let link = try await WindowsCore.shareLink { done, total in
                    MainActor.assumeIsolated {
                        self?.upload = (done, total)
                        self?.showUpload()
                    }
                }
                Clipboard.copyText(link)
                guard let self else { return }
                self.preparing = false
                self.copied = true
                self.refresh()
                try? await Task.sleep(for: .seconds(2.5))
                self.copied = false
                self.refresh()
            } catch {
                guard let self else { return }
                self.preparing = false
                self.refresh()
                let why = (error as? WindowsCore.ShareProblem)?.description ?? Words.t("Bezzle could not connect. Check the connection and try again.")
                self.questions?.tell(Words.t("“%@” could not be shared", name), why)
            }
        }
    }

    private func confirmStop() {
        let name = session.name
        questions?.ask(Words.t("Stop sharing “%@”?", name),
                       Words.t("The link stops working. Everyone who has the design keeps it as it is now, read only."),
                       action: Words.t("Stop Sharing")) { [weak self] in
            Task { @MainActor [weak self] in
                do {
                    try await WindowsCore.stopSharing()
                } catch {
                    self?.questions?.tell(Words.t("Bezzle could not stop sharing “%@”", name),
                                          Words.t("Bezzle could not connect. Check the connection and try again."))
                }
                self?.refresh()
            }
        }
    }
}

// MARK: - Asking

/// A question over the window, as the Mac asks with an alert: what it is about, what it means,
/// and the buttons, the one that does it last. Nothing else takes the pointer meanwhile; Esc
/// says Cancel and Enter the button.
@MainActor
final class Questions {
    let layer = Grid()
    private var go: (@MainActor () -> Void)?
    var isOpen: Bool { layer.visibility == .visible }

    init() {
        layer.visibility = .collapsed
        layer.background = Theme.brush(0, 0.18)
        layer.pointerPressed.addHandler { _, args in args?.handled = true }
    }

    /// Asks whether to do something: Cancel, or `action`, which does `go`.
    func ask(_ title: String, _ text: String, action: String, _ go: @escaping @MainActor () -> Void) {
        show(title, text, buttons: [(Words.t("Cancel"), false, {}), (action, true, go)])
    }

    /// Says something went wrong, with OK to put it away.
    func tell(_ title: String, _ text: String) {
        show(title, text, buttons: [(Words.t("OK"), true, {})])
    }

    func close() {
        layer.visibility = .collapsed
        layer.children.clear()
        go = nil
    }

    /// Esc and Enter, while it is open: true when the key was its.
    func key(_ args: KeyRoutedEventArgs) -> Bool {
        guard isOpen else { return false }
        args.handled = true
        if args.key == .escape { close() }
        if args.key == .enter {
            let go = go
            close()
            go?()
        }
        return true
    }

    private func show(_ title: String, _ text: String, buttons: [(String, Bool, @MainActor () -> Void)]) {
        layer.children.clear()
        let card = Border()
        card.width = 380
        card.cornerRadius = Theme.corners(16)
        card.background = Theme.brush(Theme.paper)
        card.borderBrush = Theme.hairline
        card.borderThickness = Theme.inset(0.5)
        card.horizontalAlignment = .center
        card.verticalAlignment = .center
        let stack = StackPanel()
        stack.spacing = 8
        stack.margin = Theme.inset(22, 20, 22, 18)
        let head = Theme.text(title, size: 14.5, weight: 600)
        head.textWrapping = .wrap
        stack.children.append(head)
        let words = Theme.text(text, size: 12.5, ink: 2)
        words.textWrapping = .wrap
        words.lineHeight = 18
        stack.children.append(words)
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 8
        row.horizontalAlignment = .right
        row.margin = Theme.inset(0, 10, 0, 0)
        for (title, main, action) in buttons {
            if main { go = action }
            row.children.append(button(title, main: main) { [weak self] in
                self?.close()
                action()
            })
        }
        stack.children.append(row)
        card.child = stack
        layer.children.append(card)
        layer.visibility = .visible
    }

    /// A button 28 tall: the one that does it in ink with the paper's colour on it, as Bezzle's
    /// own primary buttons are; the other on a card.
    private func button(_ title: String, main: Bool, _ action: @escaping @MainActor () -> Void) -> UIElement {
        let press = Pressable(radius: 8, action: action)
        press.hoverWash = main ? 0 : 0.06
        press.box.height = 28
        press.box.background = main ? Theme.brush(Theme.ink) : Theme.brush(Theme.card)
        press.box.borderBrush = main ? Theme.clear : Theme.hairline
        press.box.borderThickness = Theme.inset(main ? 0 : 0.5)
        let label = Theme.text(title, size: 12.5, weight: main ? 600 : 500)
        if main { label.foreground = Theme.brush(Theme.paper) }
        label.margin = Theme.inset(14, 0, 14, 0)
        label.verticalAlignment = .center
        press.box.child = label
        if main {
            press.box.pointerEntered.addHandler { sender, _ in (sender as? Border)?.background = Theme.brush(Theme.ink, 0.86) }
            press.box.pointerExited.addHandler { sender, _ in (sender as? Border)?.background = Theme.brush(Theme.ink) }
        }
        return press.box
    }
}

// MARK: - The window

extension DesignWindow {
    /// Sharing in the window: the bar's controls get the menus and the questions; whatever the
    /// share says shows at once (others' changes, the owner stopping it, a picture arriving); and
    /// someone else's design no longer shared is only looked at, as on the Mac.
    func wireSharing() {
        try? Grid.setRowSpan(questions.layer, 2)
        root.children.append(questions.layer)
        bar.sharing.menus = menus
        bar.sharing.questions = questions
        // Who else is in the live room, in the bar in place of how it is shared, their names
        // hanging over what lies under it.
        let people = canvas.liveCanvas.people
        var at: UInt32 = 0
        try? Grid.setRowSpan(people.tags, 2)
        if (try? root.children.indexOf(menus.layer, &at)) == true { try? root.children.insertAt(at, people.tags) } else { root.children.append(people.tags) }
        canvas.liveCanvas.peopleChanged = { [weak self] in
            guard let self else { return }
            self.bar.sharing.people = people.hasPeople ? people.root : nil
            self.bar.sharing.refresh()
        }
        WindowsCore.shareNews = { [weak self] in self?.shareNews() }
        session.listen { [weak self] in self?.showReadOnly() }
        showReadOnly()
    }

    /// Something about the share changed.
    func shareNews() {
        // Others' changes show as soon as nothing holds them back, as on the Mac.
        session.lookAtShare()
        if WindowsCore.tookPictures() { session.previewed(board: nil) }
        bar.sharing.refresh()
        showReadOnly()
    }

    /// Someone else's design no longer shared: the tools and the inspector rest, dimmed, and
    /// the layers list is only looked at; inspecting it still works (the Mac's readOnly).
    func showReadOnly() {
        let readOnly = WindowsCore.isReadOnly
        rail.root.opacity = readOnly ? 0.45 : 1
        rail.root.isHitTestVisible = !readOnly
        let resting = readOnly && session.mode != 2
        inspector.root.opacity = resting ? 0.45 : 1
        inspector.root.isHitTestVisible = !resting
        layers.root.isHitTestVisible = !readOnly
    }
}

// MARK: - Home

/// What home shows of how designs are shared, as the Mac's.
@MainActor
enum ShareHome {
    /// Under a shared design's name, how it is shared, in the pencil's blue (grey once someone
    /// else's is no longer shared): the Mac's DesignNote.
    static func note(for url: URL) -> UIElement? {
        guard let mark = WindowsCore.shareMark(of: url) else { return nil }
        let ended = mark == .ended
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 4
        row.margin = Theme.inset(0, -6, 0, 0)
        row.children.append(ShareWords.glyph(mark, size: 9))
        let words = Theme.text(ShareWords.title(mark), size: 11.5)
        words.foreground = ended ? Theme.ink(3) : Theme.brush(Theme.pencil)
        words.textTrimming = .characterEllipsis
        row.children.append(words)
        try? ToolTipService.setToolTip(row, ShareWords.help(mark))
        return row
    }

    /// Whether the design may be renamed here: someone else's keeps the name it was shared under.
    static func renamable(_ url: URL) -> Bool { WindowsCore.shareMark(of: url)?.renamable ?? true }

    /// Sends a design to the Recycle Bin, asking first when this computer shared it, which then
    /// stops sharing it (the Mac's Library.mayTrash and remove).
    /// `closing` comes first, once it is sure to go: its tab is closed, saved, before the file moves.
    static func recycle(_ url: URL, asking questions: Questions, closing: @escaping @MainActor () -> Void = {}, done: @escaping @MainActor (Bool) -> Void) {
        let go = {
            closing()
            WindowsCore.stopSharing(designAt: url)
            done(WindowsCore.recycle(url))
        }
        guard WindowsCore.isSharedFromHere(url) else {
            closing()
            done(WindowsCore.recycle(url))
            return
        }
        questions.ask(Words.t("Move “%@” to the Recycle Bin and stop sharing it?", url.deletingPathExtension().lastPathComponent),
                      Words.t("The link stops working. Everyone who has the design keeps it as it is now, read only."),
                      action: Words.t("Move to Recycle Bin"), go)
    }
}
