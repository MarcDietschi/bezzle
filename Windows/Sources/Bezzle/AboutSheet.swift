import Foundation
import WinUI
import UWP
import WinSDK
import BezzleCore

/// What Bezzle for Windows is made with, and under which licences: the Mac shows its own in About
/// Bezzle (Bezzle/Credits.rtf). Each line says what a part does and whose it is; its licences, as
/// the files in `licenses` beside Bezzle.exe (Windows/Credits, which build.ps1 and the installer
/// put there), open under it.
enum Credits {
    struct Part {
        /// What it does and whose it is, in Bezzle's words (translated).
        let line: String
        /// A notice its licence asks to be shown as written, in English.
        var notice: String? = nil
        /// Its licence files, in `licenses`.
        let files: [String]
    }

    static let parts: [Part] = [
        Part(line: "Bezzle draws with Skia, by Google, under the BSD licence.", files: ["skia.txt"]),
        Part(line: "Letters are read with FreeType, under the FreeType licence.",
             notice: "Portions of this software are copyright © 2026 The FreeType Project (www.freetype.org). All rights reserved.",
             files: ["freetype-ftl.txt", "freetype.txt"]),
        Part(line: "Words are shaped with HarfBuzz, under the MIT licence.", files: ["harfbuzz.txt"]),
        Part(line: "Lines are broken with ICU, by the Unicode Consortium, under the Unicode licence.", files: ["icu.txt"]),
        Part(line: "PNG pictures are read and written with libpng, under the libpng licence.", files: ["libpng.txt"]),
        Part(line: "JPEG pictures are read and written with libjpeg-turbo, under the BSD and IJG licences.",
             notice: "This software is based in part on the work of the Independent JPEG Group.",
             files: ["libjpeg-turbo.txt", "libjpeg-ijg.txt"]),
        Part(line: "WebP pictures are read and written with libwebp, by Google, under the BSD licence.", files: ["libwebp.txt", "libwebp-patents.txt"]),
        Part(line: "AVIF pictures are read and written with libavif and libaom, by the Alliance for Open Media and others, under BSD licences and the Alliance's patent licence.",
             files: ["libavif.txt", "libaom.txt", "libaom-patents.txt", "libaom-fastfeat.txt", "libaom-vector.txt"]),
        Part(line: "GIF pictures are read with Wuffs, by Google, under the Apache License 2.0.", files: ["wuffs.txt"]),
        Part(line: "Data is packed with zlib, by Jean-loup Gailly and Mark Adler, under the zlib licence.", files: ["zlib.txt"]),
        Part(line: "XML is read with Expat, under the MIT licence.", files: ["expat.txt"]),
        Part(line: "Memory for drawing is kept by PartitionAlloc, by the Chromium authors, under the BSD licence.", files: ["partition-alloc.txt"]),
        Part(line: "Designs from a Mac are unpacked with LZFSE, by Apple, under the BSD licence.", files: ["lzfse.txt"]),
        Part(line: "Bezzle is written in Swift. Its runtime and Foundation are by Apple and the Swift project authors, under the Apache License 2.0 with the Runtime Library Exception.",
             files: ["swift.txt", "swift-foundation-icu.txt"]),
        Part(line: "Its windows reach WinUI through Swift bindings by The Browser Company, under the BSD licence.",
             files: ["swift-winrt.txt", "swift-cwinrt.txt", "swift-windowsappsdk.txt"]),
        Part(line: "WinUI and the Windows App Runtime are by Microsoft, under the license terms of the Windows App SDK.",
             files: ["windows-app-sdk.txt", "windows-app-sdk-notice.txt"]),
        Part(line: "Web pages are read in WebView2, whose loader is by Microsoft, under the BSD licence.", files: ["webview2.txt"]),
        Part(line: "The Microsoft Visual C++ runtime comes with Bezzle, as Microsoft lets apps bring it along.", files: []),
        Part(line: "Updates come through WinSparkle, by Vaclav Slavik, under the MIT licence, with wxWidgets, Expat, OpenSSL and ed25519 by Orson Peters.",
             notice: "This product includes software developed by the OpenSSL Project for use in the OpenSSL Toolkit (http://www.openssl.org/). This product includes cryptographic software written by Eric Young (eay@cryptsoft.com).",
             files: ["winsparkle.txt", "wxwidgets.txt", "winsparkle-expat.txt", "openssl.txt", "ed25519.txt"]),
        Part(line: "Bezzle is installed with Inno Setup, by Jordan Russell and Martijn Laan.", files: ["inno-setup.txt"]),
        Part(line: "The fonts that stand in for the Mac's are Inter, Arimo, Tinos, Cousine, Gelasio, Jost, Libre Baskerville, Libre Bodoni, Nunito Sans and Playfair Display, each by its project's authors, under the SIL Open Font License.",
             files: ["fonts/Inter-OFL.txt", "fonts/Arimo-OFL.txt", "fonts/Tinos-OFL.txt", "fonts/Cousine-OFL.txt", "fonts/Gelasio-OFL.txt", "fonts/Jost-OFL.txt",
                     "fonts/LibreBaskerville-OFL.txt", "fonts/LibreBodoni-OFL.txt", "fonts/NunitoSans-OFL.txt", "fonts/PlayfairDisplay-OFL.txt"]),
        Part(line: "The Lucide icons are by Lucide Icons and Contributors, under the ISC licence; those derived from Feather are by Cole Bemis, under the MIT licence.", files: ["lucide.txt"]),
        Part(line: "The Phosphor icons are by Phosphor Icons, under the MIT licence.", files: ["phosphor.txt"]),
        Part(line: "The Material Symbols icons are by Google, under the Apache License 2.0.", files: ["material-symbols.txt"]),
    ]

    /// Where the licence files are: beside Bezzle.exe.
    static var folder: URL {
        URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("licenses", isDirectory: true)
    }
}

/// About Bezzle, from the Bezzle menu: the name, the version, and what Bezzle is made with, over
/// the window as the other sheets are (a card on a dimmed window; Esc, × or a click beside it
/// closes it).
@MainActor
final class AboutSheet {
    static let shared = AboutSheet()
    /// Where the window shows it: the page in front.
    var host: (() -> Grid?)?

    let layer = Grid()
    private let card = Border()
    private var page: Grid?
    private var built = false

    private init() {
        layer.visibility = .collapsed
        layer.background = Theme.brush(0, 0.18)
        layer.isTabStop = true
        layer.pointerPressed.addHandler { [weak self] _, args in
            args?.handled = true
            self?.hide()
        }
        layer.keyDown.addHandler { [weak self] _, args in
            guard let args, args.key == .escape else { return }
            args.handled = true
            self?.hide()
        }
        card.width = 560
        card.cornerRadius = Theme.corners(18)
        card.background = Theme.brush(Theme.paper)
        card.borderBrush = Theme.hairline
        card.borderThickness = Theme.inset(0.5)
        card.horizontalAlignment = .center
        card.verticalAlignment = .center
        card.margin = Theme.inset(24, 60, 24, 24)
        card.pointerPressed.addHandler { _, args in args?.handled = true }
        layer.children.append(card)
    }

    static var menuEntry: MenuHost.Entry {
        .item(Words.t("About Bezzle")) { AboutSheet.shared.show() }
    }

    func show() {
        guard let grid = host?() else { return }
        if !built { build() }
        var at: UInt32 = 0
        if let page, (try? page.children.indexOf(layer, &at)) == true { try? page.children.removeAt(at) }
        try? Grid.setRowSpan(layer, 2)
        try? Grid.setColumnSpan(layer, 4)
        grid.children.append(layer)
        page = grid
        layer.visibility = .visible
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { _ = try? self?.layer.focus(.programmatic) }
        }
    }

    func hide() {
        layer.visibility = .collapsed
    }

    private func build() {
        built = true
        let column = Grid()
        let head = RowDefinition()
        head.height = GridLength(value: 1, gridUnitType: .auto)
        let rest = RowDefinition()
        rest.height = GridLength(value: 1, gridUnitType: .star)
        column.rowDefinitions.append(head)
        column.rowDefinitions.append(rest)

        // The name as the bar writes it, the version, and the cross that closes.
        let top = StackPanel()
        top.spacing = 4
        top.margin = Theme.inset(28, 24, 28, 16)
        let title = Grid()
        let name = Theme.text("Bezzle", size: 30, weight: 500, serif: true)
        title.children.append(name)
        let closer = Pressable(radius: 8) { [weak self] in self?.hide() }
        closer.box.width = 26
        closer.box.height = 26
        closer.box.horizontalAlignment = .right
        closer.box.verticalAlignment = .top
        closer.box.child = Glyphs.view(Glyphs.cross(size: 26), size: 26, brush: Theme.ink(2))
        try? ToolTipService.setToolTip(closer.box, Words.t("Close"))
        title.children.append(closer.box)
        top.children.append(title)
        let version = Updates.version.map { Words.t("Version %@ (%@)", $0.short, $0.build) } ?? Words.t("A copy built on this computer")
        top.children.append(Theme.text(version, size: 12.5, ink: 2))
        top.children.append(Theme.text("© 2026 Erik Muffler", size: 12.5, ink: 3))
        let thanks = Theme.text(Words.t("Bezzle is made with these, with thanks to their makers."), size: 13, weight: 500)
        thanks.margin = Theme.inset(0, 14, 0, 0)
        thanks.textWrapping = .wrap
        top.children.append(thanks)
        column.children.append(top)

        // Each part: its line, a notice its licence asks for, and its licences to open.
        let list = StackPanel()
        list.spacing = 14
        list.margin = Theme.inset(28, 0, 28, 24)
        for part in Credits.parts { list.children.append(row(part)) }
        let scroll = ScrollView()
        scroll.content = list
        try? Grid.setRow(scroll, 1)
        column.children.append(scroll)
        card.child = column
        // As tall as the window allows, with room round it.
        layer.sizeChanged.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.card.maxHeight = max(240, self.layer.actualHeight - 84)
        }
    }

    private func row(_ part: Credits.Part) -> UIElement {
        let stack = StackPanel()
        stack.spacing = 4
        let line = Theme.text(Words.t(part.line), size: 12.5, ink: 1)
        line.textWrapping = .wrap
        line.textTrimming = .none
        stack.children.append(line)
        if let notice = part.notice {
            let text = Theme.text(notice, size: 11.5, ink: 2)
            text.textWrapping = .wrap
            text.textTrimming = .none
            stack.children.append(text)
        }
        guard !part.files.isEmpty else { return stack }
        // The licences, folded until asked for.
        let texts = StackPanel()
        texts.spacing = 8
        texts.visibility = .collapsed
        let toggle = Theme.text(Words.t("Show the licence"), size: 12, weight: 500)
        toggle.foreground = Theme.brush(Theme.pencil)
        let press = Pressable(radius: 6) {
            let open = texts.visibility == .collapsed
            if open, texts.children.size == 0 {
                for file in part.files { texts.children.append(Self.licence(file)) }
            }
            texts.visibility = open ? .visible : .collapsed
            toggle.text = Words.t(open ? "Hide the licence" : "Show the licence")
        }
        press.box.horizontalAlignment = .left
        press.box.height = 24
        toggle.margin = Theme.inset(0, 0, 8, 0)
        press.box.child = toggle
        stack.children.append(press.box)
        stack.children.append(texts)
        return stack
    }

    private static let mono = FontFamily("ms-appx:///fonts/Cousine-400.ttf#Cousine")

    /// A licence as its file has it, in a well, to read and copy.
    private static func licence(_ file: String) -> UIElement {
        let well = Theme.well(radius: 8)
        let text = (try? String(contentsOf: Credits.folder.appendingPathComponent(file), encoding: .utf8))
            ?? Words.t("%@ is missing beside Bezzle.", file)
        let block = TextBlock()
        block.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        block.fontFamily = mono
        block.fontSize = 10.5
        block.foreground = Theme.ink(2)
        block.textWrapping = .wrap
        block.isTextSelectionEnabled = true
        block.margin = Theme.inset(12, 10, 12, 10)
        well.child = block
        return well
    }
}
