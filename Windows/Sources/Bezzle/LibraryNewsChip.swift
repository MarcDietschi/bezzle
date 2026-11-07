import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// What changed in another design since this one took from it, offered at the top of the canvas,
/// as the Mac's LibraryNewsChip: what it is and a button. Pointing at the button shows the design
/// brought up to date, and outlines what would change; a click brings it up to date, and the
/// change runs through every copy and every layer it reaches. The × leaves it as it is, until
/// there is newer.
@MainActor
final class LibraryNewsChip {
    let root = Grid()
    private let session: DesignSession
    private let capsule = Border()
    private var shownFor: String?

    init(session: DesignSession) {
        self.session = session
        root.horizontalAlignment = .center
        root.verticalAlignment = .top
        root.margin = Theme.inset(0, 14, 0, 0)
        root.visibility = .collapsed
        capsule.height = 30
        capsule.cornerRadius = Theme.corners(15)
        capsule.background = Theme.brush(Theme.card)
        capsule.borderBrush = Theme.hairline
        capsule.borderThickness = Theme.inset(0.5)
        root.children.append(capsule)
    }

    /// Shows the first news there is, as the design is now; none while prototyping, inspecting or
    /// looking back.
    func refresh() {
        guard session.mode == 0, !WindowsCore.versions.lookingBack, let news = WindowsCore.news().first else {
            root.visibility = .collapsed
            shownFor = nil
            return
        }
        root.visibility = .visible
        let key = news.url.path + "|" + news.words
        guard key != shownFor else { return }
        shownFor = key
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 8
        let mark = Glyphs.view(Glyphs.component(size: 10), size: 10, brush: Theme.brush(Theme.linked))
        mark.verticalAlignment = .center
        mark.margin = Theme.inset(12, 0, 0, 0)
        row.children.append(mark)
        let words = Theme.text(news.words, size: 11.5)
        words.verticalAlignment = .center
        row.children.append(words)
        row.children.append(Self.updateButton(news.url, session: session) { [weak self] in self?.refresh() })
        let close = Pressable(radius: 10) { [weak self] in
            guard let self else { return }
            if WindowsCore.endPreview() { self.session.previewed(board: nil) }
            WindowsCore.setNewsAside(news.url)
            self.refresh()
        }
        close.box.width = 20
        close.box.height = 20
        close.box.margin = Theme.inset(0, 0, 4, 0)
        close.box.verticalAlignment = .center
        close.box.child = Glyphs.view(Glyphs.cross(size: 20), size: 20, brush: Theme.ink(3))
        try? ToolTipService.setToolTip(close.box, Words.t("Not Now"))
        row.children.append(close.box)
        capsule.child = row
    }

    /// Brings what changed in a library into the design; pointing at it shows how that would look.
    static func updateButton(_ url: URL, session: DesignSession, done: @escaping @MainActor () -> Void) -> FrameworkElement {
        let pill = Border()
        pill.height = 22
        pill.cornerRadius = Theme.corners(11)
        pill.padding = Theme.inset(10, 0, 10, 0)
        pill.background = Theme.brush(Theme.linked)
        pill.verticalAlignment = .center
        let label = Theme.text(Words.t("Update"), size: 11.5, weight: 600)
        label.foreground = Theme.brush(0xFFFFFF)
        label.verticalAlignment = .center
        pill.child = label
        pill.pointerEntered.addHandler { _, _ in
            pill.background = Theme.brush(Theme.mix(Theme.linked, 0x000000, 0.15))
            session.litLayers = WindowsCore.previewUpdate(from: url)
            session.previewed(board: nil)
        }
        pill.pointerExited.addHandler { _, _ in
            pill.background = Theme.brush(Theme.linked)
            WindowsCore.previewUpdate(from: nil)
            session.litLayers = []
            session.previewed(board: nil)
        }
        pill.pointerPressed.addHandler { _, args in args?.handled = true }
        pill.tapped.addHandler { _, args in
            args?.handled = true
            // Once the tap is over: what it does takes the chip, and this button, away.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    WindowsCore.previewUpdate(from: nil)
                    session.litLayers = []
                    WindowsCore.update(from: url)
                    session.edited(board: nil)
                    done()
                }
            }
        }
        return pill
    }
}
