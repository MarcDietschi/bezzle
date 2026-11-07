import Foundation
import WinSDK
import WinUI
import WindowsFoundation
import UWP
import BezzleCore

// A design's link opened on Windows, as the Mac opens one (Sharing.accept, AppDelegate's
// application(_:open:)): bezzle://share/2.<secret>, which Bezzle's page on the web hands on, or
// the page's own link, open.html#2.<secret>. Bezzle answers the bezzle: links of the person
// signed in to Windows (an installer takes that over later); one on Bezzle's command line, pasted
// or dropped on home, brings the design into the designs folder and opens it, showing it on its
// way on home meanwhile, and what went wrong there too.

/// The designs on their way from a link, and why one could not be opened, for home to show
/// (the Mac's Sharing.arriving and invitationProblem).
@MainActor
enum LinkArrivals {
    /// Each link on its way, by its words, with the design's title and owner once the room says.
    private(set) static var arriving: [(link: String, title: String, owner: String?)] = []
    static var problem: String?
    /// Something to show changed: home lists its designs again.
    static var changed: (() -> Void)?

    static func came(_ link: String) {
        arriving.append((link, Words.t("Shared Design"), nil))
        problem = nil
        changed?()
    }

    static func named(_ link: String, title: String, owner: String?) {
        guard let i = arriving.firstIndex(where: { $0.link == link }) else { return }
        arriving[i].title = title
        arriving[i].owner = owner
        changed?()
    }

    static func done(_ link: String, problem: String? = nil) {
        arriving.removeAll { $0.link == link }
        if let problem { self.problem = problem }
        changed?()
    }

    static func isArriving(_ link: String) -> Bool { arriving.contains { $0.link == link } }
}

extension BezzleApp {
    /// The design's link Bezzle was started with, if it was: the first of its arguments that is
    /// one, or that came by a bezzle: link at all (one that leads nowhere says so on home).
    @MainActor static func link(in arguments: [String]) -> String? {
        arguments.dropFirst().first { WindowsCore.isShareLink($0) || $0.lowercased().hasPrefix("bezzle:") }
    }

    /// Answers bezzle: links for the person signed in, with this copy of Bezzle, as unpackaged
    /// apps do: HKCU\Software\Classes\bezzle, opening `"Bezzle.exe" "%1"`. Written again only when
    /// it names another program.
    @MainActor func answerLinks() {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\")
        let command = "\"\(exe)\" \"%1\""
        let open = "Software\\Classes\\bezzle\\shell\\open\\command"
        guard Self.registry(open, nil) != command else { return }
        Self.setRegistry("Software\\Classes\\bezzle", nil, "URL:Bezzle")
        Self.setRegistry("Software\\Classes\\bezzle", "URL Protocol", "")
        Self.setRegistry("Software\\Classes\\bezzle\\DefaultIcon", nil, "\"\(exe)\",0")
        Self.setRegistry(open, nil, command)
    }

    private static func registry(_ key: String, _ name: String?) -> String? {
        var size: DWORD = 0
        let found = key.withCString(encodedAs: UTF16.self) { k in
            withOptionalWide(name) { n in RegGetValueW(HKEY_CURRENT_USER, k, n, DWORD(RRF_RT_REG_SZ), nil, nil, &size) }
        }
        guard found == 0, size > 0 else { return nil }
        var buffer = [UInt16](repeating: 0, count: Int(size) / 2 + 1)
        let read = key.withCString(encodedAs: UTF16.self) { k in
            withOptionalWide(name) { n in buffer.withUnsafeMutableBytes { RegGetValueW(HKEY_CURRENT_USER, k, n, DWORD(RRF_RT_REG_SZ), nil, $0.baseAddress, &size) } }
        }
        guard read == 0 else { return nil }
        return String(decodingCString: buffer, as: UTF16.self)
    }

    private static func setRegistry(_ key: String, _ name: String?, _ value: String) {
        let wide = Array(value.utf16) + [0]
        let status = key.withCString(encodedAs: UTF16.self) { k in
            withOptionalWide(name) { n in
                wide.withUnsafeBytes { RegSetKeyValueW(HKEY_CURRENT_USER, k, n, DWORD(REG_SZ), $0.baseAddress, DWORD($0.count)) }
            }
        }
        if status != 0 { Trace.say("bezzle: links not answered: \(key) \(status)") }
    }

    private static func withOptionalWide<T>(_ s: String?, _ body: (UnsafePointer<UInt16>?) -> T) -> T {
        guard let s else { return body(nil) }
        return s.withCString(encodedAs: UTF16.self) { body($0) }
    }

    /// A design's link was opened: home shows the design on its way, and it opens once it is
    /// here; one here already just opens. What went wrong shows on home, as nobody would see it
    /// anywhere else.
    @MainActor func openShareLink(_ text: String) {
        let link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WindowsCore.isShareLink(link) else {
            LinkArrivals.problem = Words.t("This link does not lead to a design.")
            Tabs.shared.showHome()
            return
        }
        guard !LinkArrivals.isArriving(link) else { return }
        LinkArrivals.came(link)
        Tabs.shared.showHome()
        let folder = Self.designsFolder
        Task { @MainActor in
            do {
                let url = try await WindowsCore.acceptLink(link, into: folder) { title, owner in
                    MainActor.assumeIsolated { LinkArrivals.named(link, title: title, owner: owner) }
                }
                LinkArrivals.done(link)
                Tabs.shared.open(url)
            } catch {
                let why = (error as? WindowsCore.ShareProblem)?.description
                    ?? Words.t("Bezzle could not reach the design. Check the connection and open the link again.")
                LinkArrivals.done(link, problem: why)
            }
        }
    }

    /// Bezzle coming to the front looks at the open design's room at once, and tries again to
    /// stop the shares still to stop (the Mac's applicationDidBecomeActive).
    @MainActor func watchActivation() {
        LinkArrivals.changed = { Tabs.shared.home()?.refresh() }
        #if DEBUG
        // BEZZLE_ARRIVING=Title|Owner: a design on its way that never comes, to look at on home
        // (the Mac's pretendArriving).
        if let given = ProcessInfo.processInfo.environment["BEZZLE_ARRIVING"] {
            let parts = given.split(separator: "|").map(String.init)
            LinkArrivals.came("debug")
            LinkArrivals.named("debug", title: parts.first ?? "", owner: parts.count > 1 ? parts[1] : nil)
        }
        #endif
        WindowsCore.stopWhatIsLeft()
        window?.activated.addHandler { _, args in
            guard args?.windowActivationState != .deactivated else { return }
            MainActor.assumeIsolated { WindowsCore.cameToFront() }
        }
    }
}

extension Clipboard {
    /// The words on the clipboard, if there are any.
    static var text: String? {
        guard IsClipboardFormatAvailable(UINT(CF_UNICODETEXT)), OpenClipboard(nil) else { return nil }
        defer { CloseClipboard() }
        guard let h = GetClipboardData(UINT(CF_UNICODETEXT)), let p = GlobalLock(h) else { return nil }
        defer { GlobalUnlock(h) }
        return String(decodingCString: p.assumingMemoryBound(to: UInt16.self), as: UTF16.self)
    }
}

// MARK: - On home

extension ShareHome {
    /// The designs on their way from a link, and a link that could not be opened, in the places
    /// their designs take among the others: the Mac's ArrivingCard and UnopenedCard.
    static func arrivalCards(width: Double) -> [UIElement] {
        var cards: [UIElement] = []
        if let problem = LinkArrivals.problem { cards.append(unopened(problem, width: width)) }
        for arrival in LinkArrivals.arriving { cards.append(ArrivingCard(title: arrival.title, owner: arrival.owner, width: width).root) }
        return cards
    }

    /// A link that could not be opened: the sheet left lying askew, why, and Dismiss.
    private static func unopened(_ problem: String, width: Double) -> UIElement {
        let column = StackPanel()
        column.spacing = 10
        column.width = width
        let well = Grid()
        well.width = width
        well.height = width * 300 / 480
        well.cornerRadius = Theme.corners(12)
        well.background = Theme.brush(Theme.table)
        well.borderBrush = Theme.hairline
        well.borderThickness = Theme.inset(0.5)
        let sheet = Border()
        sheet.width = 66
        sheet.height = 88
        sheet.background = Theme.brush(Theme.dark ? 0xF4F1EB : 0xFFFFFF, 0.7)
        sheet.isHitTestVisible = false
        let tilt = CompositeTransform()
        tilt.rotation = -7
        tilt.centerX = 33
        tilt.centerY = 44
        sheet.renderTransform = tilt
        // Its rim dashed, as a sheet only drawn round.
        let rim = WinUI.Rectangle()
        rim.stroke = Theme.ink(4)
        rim.strokeThickness = 1
        let dashes = DoubleCollection()
        dashes.append(3)
        dashes.append(3)
        rim.strokeDashArray = dashes
        sheet.child = rim
        well.children.append(sheet)
        let mark = Glyphs.view(Glyphs.warning(size: 18), size: 18, brush: Theme.brush(Theme.warning))
        mark.horizontalAlignment = .center
        mark.verticalAlignment = .center
        mark.margin = Theme.inset(52, 60, 0, 0)
        well.children.append(mark)
        column.children.append(well)
        let head = Grid()
        let title = Theme.text(Words.t("Could not be opened"), size: 15, serif: true)
        head.children.append(title)
        let dismiss = ExportSheet.textButton("Dismiss") {
            LinkArrivals.problem = nil
            LinkArrivals.changed?()
        }
        (dismiss as? FrameworkElement)?.horizontalAlignment = .right
        (dismiss as? FrameworkElement)?.margin = Theme.inset(0, -4, -6, -4)
        head.children.append(dismiss)
        column.children.append(head)
        let why = Theme.text(problem, size: 11.5, ink: 3)
        why.margin = Theme.inset(0, -6, 0, 0)
        try? ToolTipService.setToolTip(why, problem)
        column.children.append(why)
        return column
    }
}

/// A design someone shared, on its way: a blank sheet settling onto its table while what is on
/// it is laid in, line by line, pencil first, then ink, and again, until the design's own card
/// takes its place (the Mac's ArrivingCard and ArrivingSheet).
@MainActor
final class ArrivingCard {
    let root = StackPanel()
    private let sheet = Border()
    private let turn = CompositeTransform()
    private var lines: [(track: Border, laid: Border, length: Double)] = []
    private var ticking: EventCleanup?
    private let began = WindowsCore.now

    init(title: String, owner: String?, width: Double) {
        root.spacing = 10
        root.width = width
        let well = Grid()
        well.width = width
        well.height = width * 300 / 480
        well.cornerRadius = Theme.corners(12)
        well.background = Theme.brush(Theme.table)
        well.borderBrush = Theme.hairline
        well.borderThickness = Theme.inset(0.5)
        sheet.width = 66
        sheet.height = 88
        sheet.background = Theme.brush(Theme.dark ? 0xF4F1EB : 0xFFFFFF)
        sheet.horizontalAlignment = .center
        sheet.verticalAlignment = .center
        turn.centerX = 33
        turn.centerY = 44
        sheet.renderTransform = turn
        let stack = StackPanel()
        stack.spacing = 5
        stack.margin = Theme.inset(10)
        let heading = Border()
        heading.width = 26
        heading.height = 5
        heading.cornerRadius = Theme.corners(1.5)
        heading.background = Theme.ink(4)
        heading.horizontalAlignment = .left
        heading.margin = Theme.inset(0, 0, 0, 3)
        stack.children.append(heading)
        for length in [0.78, 0.56, 0.9, 0.64, 0.42] {
            let track = Border()
            track.width = 44 * length
            track.height = 3
            track.cornerRadius = Theme.corners(1.5)
            track.background = Theme.brush(Theme.ink, 0.06)
            track.horizontalAlignment = .left
            let laid = Border()
            laid.height = 3
            laid.width = 0
            laid.cornerRadius = Theme.corners(1.5)
            laid.horizontalAlignment = .left
            track.child = laid
            stack.children.append(track)
            lines.append((track, laid, length))
        }
        sheet.child = stack
        well.children.append(sheet)
        root.children.append(well)
        let name = Theme.text(title, size: 15, serif: true)
        root.children.append(name)
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 4
        row.margin = Theme.inset(0, -6, 0, 0)
        let glyph = Glyphs.view(Glyphs.share(size: 9), size: 9, brush: Theme.brush(Theme.pencil))
        glyph.verticalAlignment = .center
        row.children.append(glyph)
        let from = Theme.text(owner.map { Words.t("Arriving from %@", $0) } ?? Words.t("Shared Design"), size: 11.5)
        from.foreground = Theme.brush(Theme.pencil)
        row.children.append(from)
        root.children.append(row)
        step()
        // Held by its own frames until it leaves the page: home keeps only what it shows.
        ticking = CompositionTarget.rendering.addHandler { _, _ in MainActor.assumeIsolated { self.step() } }
        root.unloaded.addHandler { [weak self] _, _ in
            self?.ticking?.dispose()
            self?.ticking = nil
        }
    }

    /// The sheet as it is at this moment: drifting gently as it settles, its lines filling in
    /// one after another every 2.6 s.
    private func step() {
        let time = WindowsCore.now - began
        let drift = sin(time * 1.3)
        turn.rotation = -1.2 + 1.1 * sin(time * 0.8)
        turn.translateY = -2 * drift
        let cycle = (time / 2.6).truncatingRemainder(dividingBy: 1)
        for (i, line) in lines.enumerated() {
            let start = Double(i) * 0.13
            let laid = min(max((cycle - start) / 0.3, 0), 1)
            let eased = 1 - pow(1 - laid, 3)
            line.laid.width = 44 * line.length * eased
            line.laid.background = laid < 1 ? Theme.brush(Theme.pencil, 0.55) : Theme.ink(4)
        }
    }
}
