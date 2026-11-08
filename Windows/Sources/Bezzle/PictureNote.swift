import Foundation
import WinSDK
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// Why photos in the design show as a quiet grey, as the Mac shows a picture that is missing, when
/// they are HEIC pictures (as an iPhone takes them) and Windows lacks what reads them: Microsoft's
/// HEIF Image Extensions, or its HEVC Video Extensions (Host/PictureReading.swift). A card at the
/// top of the canvas, which opens the extension's page in the Microsoft Store; the × leaves it be
/// while the design is open.
@MainActor
final class PictureNote {
    let root = Grid()
    private let session: DesignSession
    private var shown: WindowsCore.PictureTrouble?
    private var setAside = false

    /// The extensions' pages in the Microsoft Store.
    private static let heifPage = "ms-windows-store://pdp/?ProductId=9PMMSR1CGPWG"
    private static let hevcPage = "ms-windows-store://pdp/?ProductId=9NMZLZ57R3T7"

    init(session: DesignSession) {
        self.session = session
        root.horizontalAlignment = .center
        root.verticalAlignment = .top
        root.margin = Theme.inset(28, 52, 28, 0)
        root.maxWidth = 520
        root.visibility = .collapsed
    }

    /// Shows why, as the design is now; nothing when every picture in it shows.
    func refresh() {
        let trouble = setAside ? nil : WindowsCore.heifNote
        guard let trouble else {
            root.visibility = .collapsed
            shown = nil
            return
        }
        root.visibility = .visible
        guard trouble != shown else { return }
        shown = trouble
        root.children.clear()
        let card = Theme.card(radius: 12)
        card.padding = Theme.inset(14, 10, 8, 10)
        let row = Grid()
        let text = ColumnDefinition()
        text.width = GridLength(value: 1, gridUnitType: .star)
        row.columnDefinitions.append(text)
        for _ in 0..<2 {
            let fit = ColumnDefinition()
            fit.width = GridLength(value: 1, gridUnitType: .auto)
            row.columnDefinitions.append(fit)
        }
        let words = Theme.text(trouble == .needsHEIF
            ? Words.t("Some photos in this design are HEIC pictures, which Windows reads only with Microsoft’s HEIF Image Extensions and HEVC Video Extensions. Until it has them, the photos show in grey.")
            : Words.t("Some photos in this design are HEIC pictures, which Windows reads only with Microsoft’s HEVC Video Extensions. Until it has them, the photos show in grey."),
            size: 11.5, ink: 2)
        words.textWrapping = .wrap
        words.verticalAlignment = .center
        row.children.append(words)
        // The page of the extension it lacks, as the Mac's chips have their one filled button.
        let store = Border()
        store.height = 22
        store.cornerRadius = Theme.corners(11)
        store.padding = Theme.inset(10, 0, 10, 0)
        store.margin = Theme.inset(12, 0, 4, 0)
        store.verticalAlignment = .center
        store.background = Theme.brush(Theme.pencil)
        let label = Theme.text(Words.t("Microsoft Store"), size: 11.5, weight: 600)
        label.foreground = Theme.brush(0xFFFFFF)
        label.verticalAlignment = .center
        store.child = label
        store.pointerEntered.addHandler { _, _ in store.background = Theme.brush(Theme.mix(Theme.pencil, 0x000000, 0.15)) }
        store.pointerExited.addHandler { _, _ in store.background = Theme.brush(Theme.pencil) }
        store.pointerPressed.addHandler { _, args in args?.handled = true }
        let page = trouble == .needsHEIF ? Self.heifPage : Self.hevcPage
        store.tapped.addHandler { _, args in
            args?.handled = true
            Self.open(page)
        }
        try? Grid.setColumn(store, 1)
        row.children.append(store)
        let close = Pressable(radius: 10) { [weak self] in
            self?.setAside = true
            self?.refresh()
        }
        close.box.width = 20
        close.box.height = 20
        close.box.verticalAlignment = .center
        close.box.child = Glyphs.view(Glyphs.cross(size: 20), size: 20, brush: Theme.ink(3))
        try? ToolTipService.setToolTip(close.box, Words.t("Not Now"))
        try? Grid.setColumn(close.box, 2)
        row.children.append(close.box)
        card.child = row
        root.children.append(card)
    }

    private static func open(_ link: String) {
        _ = "open".withCString(encodedAs: UTF16.self) { verb in
            link.withCString(encodedAs: UTF16.self) { file in
                ShellExecuteW(nil, verb, file, nil, nil, Int32(SW_SHOWNORMAL))
            }
        }
    }
}
