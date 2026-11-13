import AppKit
import SwiftUI
import WebKit

/// Bezzle's own browser, for the screens of a web app that a plain import cannot reach: those
/// behind a sign-in, or a click or two away from any address. A person signs in and clicks
/// through in its window and imports the page as it shows it, open menus, results and all, its
/// scrolling boxes scrolled where they are (`importShown`); an assistant does the same through the AI server (`browse`), the window out
/// of sight. Each page comes into a design beside what is there (`DocumentStore.bringIn`).
///
/// Its sign-ins are kept where web imports keep theirs (`WebCapture.dataStore`), so they hold
/// for plain imports too, and from one launch to the next.
@MainActor @Observable
final class WebBrowser {
    static let shared = WebBrowser()

    enum Failure: LocalizedError {
        case nothingOpen
        case page(String)
        case gone

        var errorDescription: String? {
            switch self {
            case .nothingOpen: String(localized: "The browser has no page open.")
            case .page(let why): why
            case .gone: String(localized: "The design to bring the page into is closed.")
            }
        }
    }

    /// What a page brought in became: artboards of a design.
    struct Brought {
        let store: DocumentStore
        let ids: [UUID]
        let report: ImportReport
        /// Pages asked for that could not be read, and so are not among them.
        var missed: [URL] = []
    }

    /// The width the page is laid out at, and the height of the window it is read in.
    private(set) var size: WebCapture.Size = .desktop
    private(set) var url: URL?
    private(set) var title = ""
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var loading = false
    /// While the page is being brought in: what is being done, and how far it has come, 0…1.
    private(set) var stage: String?
    private(set) var progress: Double?
    /// What went wrong the last time, until the next try.
    private(set) var failure: String?
    /// For a moment after a page came in, so the button can say so.
    private(set) var justImported = false
    /// Whether its window is on screen for a person.
    private(set) var shown = false
    /// The address in the window's address field, as typed.
    var typed = ""
    /// The design pages are brought into; nil for a new one, made with the first page.
    @ObservationIgnored weak var destination: DocumentStore? { didSet { destinationName = destination?.name; label() } }
    private(set) var destinationName: String?
    /// Whether the window pages are read in out of sight is put on screen, though no one sees it,
    /// as `WebCapture.showsWindow`. Test runs show no windows.
    @ObservationIgnored var showsStash = !BezzleApp.isTesting

    var importing: Bool { progress != nil }
    var canImport: Bool { url != nil && !importing && !loading }

    @ObservationIgnored private var web: WKWebView?
    /// Where the web view is kept out of sight, at its full size: while an assistant browses, and
    /// while a page is read.
    @ObservationIgnored private var stash: NSWindow?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var pane: BrowserPane?
    @ObservationIgnored private var watches: [NSKeyValueObservation] = []
    @ObservationIgnored private let guide = Guide()
    @ObservationIgnored private var idle: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    private let world = WKContentWorld.world(name: "BezzleReader")

    /// Its hands, read once from the app.
    static let handsScript = WebCapture.resource("WebPageHands")
    /// No scroll bars, which would take room from the page and show in what is photographed.
    static let noBars = """
        (() => {
          const bars = document.createElement('style');
          bars.textContent = 'html, * { scrollbar-width: none !important; } ::-webkit-scrollbar { display: none !important; width: 0 !important; height: 0 !important; }';
          (document.head || document.documentElement).appendChild(bars);
        })();
        """
    /// The height of the bar over the page.
    static let barHeight: CGFloat = 52

    init() { guide.browser = self }

    // MARK: The page

    /// The web view, made the first time: the reader and the hands in their world, the recorder
    /// of its WebGL in the page's (WebPageGL.js), and of what a page read is given before its own
    /// scripts (WebPageAwake.js) only that it shows no scroll bars, so it runs as it does in any
    /// browser but is laid out as wide as it is read.
    private func webView() -> WKWebView {
        if let web { return web }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WebCapture.dataStore
        config.suppressesIncrementalRendering = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.preferences.isElementFullscreenEnabled = false
        config.preferences.inactiveSchedulingPolicy = .none
        config.userContentController.addUserScript(WKUserScript(source: Self.noBars, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        config.userContentController.addUserScript(WKUserScript(source: WebCapture.recorder, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        config.userContentController.addUserScript(WKUserScript(source: WebCapture.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        config.userContentController.addUserScript(WKUserScript(source: Self.handsScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        let web = WKWebView(frame: CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height)), configuration: config)
        web.navigationDelegate = guide
        web.uiDelegate = guide
        web.customUserAgent = size.mobile ? WebCapture.mobileAgent : WebCapture.desktopAgent
        web.allowsBackForwardNavigationGestures = true
        watches = [
            web.observe(\.url) { [weak self] web, _ in MainActor.assumeIsolated { self?.followed(web) } },
            web.observe(\.title) { [weak self] web, _ in MainActor.assumeIsolated { self?.followed(web) } },
            web.observe(\.canGoBack) { [weak self] web, _ in MainActor.assumeIsolated { self?.followed(web) } },
            web.observe(\.canGoForward) { [weak self] web, _ in MainActor.assumeIsolated { self?.followed(web) } },
            web.observe(\.isLoading) { [weak self] web, _ in MainActor.assumeIsolated { self?.followed(web) } },
        ]
        self.web = web
        putAway(web)
        return web
    }

    private func followed(_ web: WKWebView) {
        guard web === self.web else { return }
        let was = url
        url = web.url
        title = web.title ?? ""
        canGoBack = web.canGoBack
        canGoForward = web.canGoForward
        loading = web.isLoading
        if url != was, let url { typed = url.isFileURL ? url.path : url.absoluteString }
        label()
    }

    /// The web view of the page open, or why there is none.
    private func page() throws -> WKWebView {
        guard let web, web.url != nil else { throw Failure.nothingOpen }
        return web
    }

    /// Opens a page and waits until it has loaded and settled.
    func open(_ url: URL) async throws {
        let web = webView()
        touch()
        guide.failure = nil
        if url.isFileURL { web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) } else { web.load(URLRequest(url: url, timeoutInterval: 30)) }
        try await settle(most: 30)
    }

    /// Goes to what was typed into the address field.
    func go(_ typed: String) {
        guard let url = WebCapture.address(typed) else {
            fail(String(localized: "That is not a web address Bezzle can open."))
            return
        }
        fail(nil)
        run { try await self.open(url) }
    }

    func back() { web?.goBack(); touch() }
    func forward() { web?.goForward(); touch() }
    func reload() { web?.reload(); touch() }

    /// Waits for what a step set going: the page loading, then a moment with nothing changing.
    func settle(most: TimeInterval = 20) async throws {
        guard let web else { return }
        let begun = Date()
        try await Task.sleep(for: .milliseconds(120))
        while web.isLoading && Date().timeIntervalSince(begun) < most {
            if let failure = guide.failure { guide.failure = nil; throw failure }
            try await Task.sleep(for: .milliseconds(80))
        }
        if let failure = guide.failure { guide.failure = nil; throw failure }
        _ = try? await hands("return await __bezzleHands.settle(still, most)", ["still": 350, "most": 6000])
    }

    /// Lays the page out at another size: a phone's tells the page so, and is loaded again.
    func resize(to size: WebCapture.Size) {
        let phone = size.mobile != self.size.mobile
        self.size = size
        guard let web else { return }
        web.customUserAgent = size.mobile ? WebCapture.mobileAgent : WebCapture.desktopAgent
        if let pane, web.superview === pane { pane.layOut(web, size: size) } else { putAway(web) }
        if let window, let pane { window.setContentSize(pane.fitting(size)) }
        if phone, web.url != nil { web.reload() }
    }

    // MARK: Hands, for an assistant

    /// The page as an assistant is told of it, as JSON: its address and title, how far it is
    /// scrolled, what one can press or fill in, numbered, its dialogs and menus, and its words.
    func look(words: Int? = nil) async throws -> String {
        _ = try page()
        touch()
        guard let json = try await hands("return __bezzleHands.look(opts)", ["opts": ["words": words ?? 3000]]) as? String,
              var object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { throw Failure.page("The page could not be looked at.") }
        object["window"] = shown ? "shown to the person" : "out of sight"
        object["into"] = destination?.name
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// What `target` names: a number from the last look, or words on the thing; or `selector`.
    private func aim(_ target: Any?, _ selector: String?) -> [String: Any] {
        ["target": target ?? NSNull(), "selector": selector ?? NSNull()]
    }

    func click(_ target: Any?, selector: String? = nil) async throws -> String {
        try await step("return __bezzleHands.click(target, selector)", aim(target, selector))
    }

    func hover(_ target: Any?, selector: String? = nil) async throws -> String {
        try await step("return __bezzleHands.hover(target, selector)", aim(target, selector))
    }

    /// Types words into a field, in place of what is in it unless `add`; never into a password.
    func type(_ text: String, into target: Any?, selector: String? = nil, submit: Bool = false, add: Bool = false) async throws -> String {
        var args = aim(target, selector)
        args["text"] = text
        args["submit"] = submit
        args["add"] = add
        return try await step("return __bezzleHands.type(target, selector, text, submit, add)", args)
    }

    func press(_ key: String) async throws -> String {
        try await step("return __bezzleHands.press(key)", ["key": key])
    }

    /// Scrolls a thing into view, or the page to "top", "bottom" or a height, or by a distance.
    func scroll(_ target: Any?, selector: String? = nil, to: Any? = nil, by: Double? = nil) async throws -> String {
        var args = aim(target, selector)
        args["to"] = to ?? NSNull()
        args["by"] = by ?? NSNull()
        return try await step("return __bezzleHands.scroll(target, selector, to, by)", args)
    }

    private func step(_ body: String, _ args: [String: Any]) async throws -> String {
        _ = try page()
        touch()
        let said = try await hands(body, args) as? String ?? ""
        try await settle()
        return said
    }

    /// Calls the hands in their world, putting them there first when the page came in before
    /// they could be.
    private func hands(_ body: String, _ args: [String: Any]) async throws -> Any? {
        guard let web else { throw Failure.nothingOpen }
        let there = try? await web.callAsyncJavaScript("return typeof __bezzleHands", arguments: [:], in: nil, contentWorld: world) as? String
        if there != "object" { _ = try? await web.evaluateJavaScript(Self.handsScript + "\n;true", in: nil, contentWorld: world) }
        do {
            return try await web.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: world)
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            throw Failure.page(message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message)
        }
    }

    /// What the window shows of the page, as a PNG no wider than 1440 pixels.
    func picture() async throws -> Data? {
        let web = try page()
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        config.snapshotWidth = NSNumber(value: Double(min(web.bounds.width, 1440)))
        let image = try await web.takeSnapshot(configuration: config)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    // MARK: Bringing the page in

    /// Reads the page as it is now, signed in, clicked through and typed into, and brings it in:
    /// into `store`, or else the design the last page went into, or else a new design, which
    /// the pages after it go into too. The page is left as it was.
    @discardableResult
    func importShown(name: String? = nil, into store: DocumentStore? = nil) async throws -> Brought {
        _ = try page()
        begin()
        defer { end() }
        var (read, held) = try await readShown { [weak self] what, done in self?.say(what, done) }
        read.name = Self.given(name) ?? Self.boardName(of: read.page, size: size, among: (store ?? destination)?.doc.nodes ?? [])
        return try bring([read], held: held, into: store)
    }

    /// Brings several pages in at once, side by side in one design and one step of its undo
    /// history: the page open as it shows now, and the others loaded one after another out of
    /// sight, signed in as the browser is, while the page open stays as it is. A page that cannot
    /// be read is left out and said so (`Brought.missed`).
    @discardableResult
    func importPages(_ chosen: [Page], into store: DocumentStore? = nil) async throws -> Brought {
        _ = try page()
        guard !chosen.isEmpty else { throw Failure.page(String(localized: "Choose the pages to import.")) }
        begin()
        done = []
        defer {
            reading = nil
            end()
        }
        let capture = WebCapture()
        capture.showsWindow = showsStash
        defer { capture.close() }
        var reads: [WebRead] = [], held: [String: Data] = [:], missed: [URL] = []
        var named = (store ?? destination)?.doc.nodes ?? []
        let here = url.map(Self.plain)
        for (i, page) in chosen.enumerated() {
            try Task.checkCancellation()
            reading = page.id
            let lead = chosen.count > 1 ? String(localized: "Page \(i + 1) of \(chosen.count)") + ": " : ""
            let tell: (String, Double) -> Void = { [weak self] what, part in
                self?.say(lead + what, (Double(i) + part) / Double(chosen.count))
            }
            do {
                var (read, pictures): (WebRead, [String: Data])
                if Self.plain(page.url) == here {
                    (read, pictures) = try await readShown(tell)
                } else {
                    capture.progress = tell
                    (read, pictures) = try await capture.read(page.url, size: size)
                }
                read.name = Self.boardName(of: read.page, size: size, among: named)
                named.append(Node(kind: .artboard, name: read.name, frame: .zero))
                reads.append(read)
                held.merge(pictures) { a, _ in a }
                done.insert(page.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                missed.append(page.url)
            }
        }
        guard !reads.isEmpty else { throw Failure.page(String(localized: "None of the pages could be read.")) }
        var brought = try bring(reads, held: held, into: store)
        brought.missed = missed
        if !missed.isEmpty { fail(String(localized: "\(missed.count) pages could not be read.")) }
        return brought
    }

    /// The page as it is in the browser, read out of sight at its full size while the window
    /// holds a picture of it still, and left as it was.
    private func readShown(_ tell: @escaping (String, Double) -> Void) async throws -> (WebRead, [String: Data]) {
        let web = try page()
        let inWindow = shown
        if inWindow { _ = await pane?.freeze(web) }
        putAway(web, reading: true)
        defer {
            if inWindow, shown, let pane {
                pane.thaw(web, size: size)
                stash?.orderOut(nil)
            }
        }
        try await Task.sleep(for: .milliseconds(150))
        let capture = WebCapture(adopting: web)
        capture.progress = tell
        defer { capture.close() }
        return try await capture.readAsShown(size: size)
    }

    /// Pages read, brought into `store`, or else the design the last pages went into, or else a
    /// new design, opened behind the browser, which the pages after them go into too.
    private func bring(_ reads: [WebRead], held: [String: Data], into store: DocumentStore?) throws -> Brought {
        let source = WebImport.source(of: web?.url ?? url ?? URL(fileURLWithPath: "/"))
        if let target = store ?? destination {
            guard MCPTools.stores.contains(where: { $0 === target }) else { throw Failure.gone }
            let (ids, report) = try target.bringIn(reads, held: held, source: source)
            destination = target
            imported()
            return Brought(store: target, ids: ids, report: report)
        }
        let (design, report) = try WebImport.write(reads, held: held, source: source, into: Library.shared.folder)
        Library.shared.refresh()
        Tabs.shared.open(design, report: report.lines.isEmpty ? nil : report)
        guard let made = Tabs.shared.designs.first(where: { $0.shows(design) })?.store else { throw Failure.gone }
        destination = made
        imported()
        return Brought(store: made, ids: made.doc.nodes.filter(\.isArtboard).map(\.id), report: report)
    }

    private func begin() {
        touch()
        fail(nil)
        stage = String(localized: "Scrolling through the page…")
        progress = 0.02
    }

    private func end() {
        stage = nil
        progress = nil
        touch()
    }

    private func say(_ what: String, _ part: Double) {
        stage = what
        progress = max(progress ?? 0, part * 0.95)
    }

    private static func given(_ name: String?) -> String? {
        name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Pages

    /// A page that can be brought in: the one open, one visited before, or one it links to.
    struct Page: Identifiable, Hashable {
        enum Kind { case open, visited, linked }
        var url: URL
        var name: String
        var kind: Kind
        var id: String { WebBrowser.plain(url).absoluteString }
    }

    /// The pages offered, the one open first, then those visited, then those it links to.
    private(set) var pages: [Page] = []
    /// Those chosen to be brought in, by id.
    var chosen: Set<String> = []
    /// While pages are brought in: the one being read, and those read.
    private(set) var reading: String?
    private(set) var done: Set<String> = []

    /// An address without the part after #, which names a place on a page and not a page.
    nonisolated static func plain(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.fragment = nil
        return parts.url ?? url
    }

    /// What signs a person out or does something rather than show a page, as the hands tell it
    /// (WebPageHands.js), so a page visited before is offered only when loading it again is safe.
    nonisolated static func doesSomething(_ url: URL) -> Bool {
        let path = url.path + (url.query.map { "?" + $0 } ?? "")
        let pattern = #"(^|[/_.-])(log-?out|sign-?out|signoff|abmelden|ausloggen|deconnexion|disconnetti|esci|delete|remove|unsubscribe)([/_.?-]|$)|/api/|/auth/"#
        return path.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Finds the pages to offer: the one open, those visited in the browser, newest first, and
    /// those the page links to, each once. Only the open page is chosen at first.
    @discardableResult
    func findPages() async -> [Page] {
        guard let web, let here = web.url else { pages = []; return [] }
        var found = [Page(url: Self.plain(here), name: title.isEmpty ? (here.host ?? here.absoluteString) : title, kind: .open)]
        var seen: Set<String> = [found[0].id]
        let list = web.backForwardList
        for item in (list.backList.reversed() + list.forwardList) {
            let page = Page(url: Self.plain(item.url), name: item.title?.isEmpty == false ? item.title! : item.url.path, kind: .visited)
            guard item.url.host == here.host, item.url.scheme == here.scheme, !Self.doesSomething(item.url), seen.insert(page.id).inserted else { continue }
            found.append(page)
        }
        if let json = try? await hands("return __bezzleHands.pages(opts)", ["opts": ["limit": 200]]) as? String,
           let links = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] {
            for link in links {
                guard let address = link["url"] as? String, let to = URL(string: address) else { continue }
                let page = Page(url: Self.plain(to), name: link["name"] as? String ?? to.path, kind: .linked)
                guard seen.insert(page.id).inserted else { continue }
                found.append(page)
            }
        }
        pages = found
        chosen = chosen.intersection(found.map(\.id))
        if chosen.isEmpty { chosen = [found[0].id] }
        return found
    }

    /// The person's Import button in the list of pages: those chosen, into the design chosen.
    func importChosen() {
        let chosen = pages.filter { self.chosen.contains($0.id) }
        guard !chosen.isEmpty, !importing else { return }
        run { try await self.importPages(chosen) }
    }

    /// Stops pages being brought in; those read so far are not brought in.
    func cancelWork() {
        work?.cancel()
    }

    /// What a page's artboard is called: the page's title, or its address's path, with its
    /// size when that is not a desktop's; numbered when the design has that name already.
    static func boardName(of page: WebPage, size: WebCapture.Size, among nodes: [Node]) -> String {
        var name = page.title.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).joined(separator: " ")
        if name.isEmpty { name = URL(string: page.url)?.path ?? "" }
        if name.isEmpty || name == "/" { name = URL(string: page.url)?.host ?? String(localized: "Web Page") }
        if name.count > 60 { name = String(name.prefix(60)).trimmingCharacters(in: .whitespaces) + "…" }
        if size.width != WebCapture.Size.desktop.width { name += " (\(size.name))" }
        let taken = Set(nodes.filter(\.isArtboard).map(\.name))
        guard taken.contains(name) else { return name }
        var n = 2
        while taken.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }

    private func imported() {
        justImported = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            self?.justImported = false
        }
    }

    /// The person's Import button: the page into the design chosen, saying what went wrong.
    func importFromWindow() {
        guard canImport else { return }
        run { try await self.importShown() }
    }

    private func run(_ job: @escaping () async throws -> Void) {
        work?.cancel()
        work = Task { [weak self] in
            do { try await job() } catch is CancellationError {
            } catch {
                self?.fail(error.localizedDescription)
            }
        }
    }

    // MARK: Windows

    /// Puts the browser's window on screen for a person, at `address` if one is given, bringing
    /// pages into `store`, or a new design when none is.
    func show(_ address: URL? = nil, size: WebCapture.Size? = nil, into store: DocumentStore?, activate: Bool = true) {
        destination = store
        if let size { resize(to: size) }
        let web = webView()
        let window = self.window ?? makeWindow()
        guard let pane else { return }
        pane.thaw(web, size: self.size)
        window.setContentSize(pane.fitting(self.size))
        stash?.orderOut(nil)
        if !shown { window.center() }
        shown = true
        label()
        if activate {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
        if let address { run { try await self.open(address) } }
    }

    /// Takes the window off the screen; the page stays open out of sight for an assistant.
    func hide() {
        guard let window else { return }
        window.orderOut(nil)
        windowClosed()
    }

    /// Lets go of the page and its windows. Its sign-ins stay.
    func close() {
        work?.cancel()
        idle?.cancel()
        window?.orderOut(nil)
        shown = false
        watches = []
        web?.stopLoading()
        web?.removeFromSuperview()
        web = nil
        stash?.orderOut(nil)
        stash?.contentView = nil
        url = nil
        title = ""
        loading = false
    }

    fileprivate func windowClosed() {
        shown = false
        if let web { putAway(web) }
        touch()
    }

    private func makeWindow() -> NSWindow {
        let pane = BrowserPane(bar: NSHostingView(rootView: WebBrowserBar(browser: self)))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: pane.fitting(size)), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = pane
        window.delegate = guide
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NSColor(Theme.paper)
        self.pane = pane
        self.window = window
        return window
    }

    private func fail(_ message: String?) {
        failure = message
        label()
    }

    /// The window's title, the page's own, and under it where its pages go, or what went wrong.
    private func label() {
        guard let window else { return }
        window.title = title.isEmpty ? (url?.host ?? String(localized: "Import from a Website")) : title
        if let failure {
            window.subtitle = failure
        } else if let destinationName {
            window.subtitle = String(localized: "Into \(destinationName)")
        } else {
            window.subtitle = String(localized: "Into a new design")
        }
    }

    /// The web view out of sight at its full size, in a window of its own as `WebCapture`'s.
    private func putAway(_ web: WKWebView, reading: Bool = false) {
        let frame = CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height))
        if stash == nil {
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.isExcludedFromWindowsMenu = true
            window.collectionBehavior = [.transient, .ignoresCycle, .stationary, .fullScreenAuxiliary]
            window.level = .floating
            stash = window
        }
        guard let stash else { return }
        if web.superview !== stash.contentView, stash.contentView !== web {
            web.removeFromSuperview()
            stash.contentView = web
        }
        stash.setContentSize(frame.size)
        web.frame = frame
        if let screen = NSScreen.main { stash.setFrameOrigin(CGPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY)) }
        if showsStash && (!shown || reading) { stash.orderFrontRegardless() }
    }

    /// Keeps the page awake while it is used, and lets it go when it has not been for a while:
    /// out of sight after a minute and a half, and closed after twenty minutes, its window not shown.
    private func touch() {
        if showsStash, !shown, let stash, stash.contentView === web { stash.orderFrontRegardless() }
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard let self, !Task.isCancelled, !self.shown, !self.importing else { return }
            self.stash?.orderOut(nil)
            try? await Task.sleep(for: .seconds(20 * 60 - 90))
            guard !Task.isCancelled, !self.shown, !self.importing else { return }
            self.close()
        }
    }

    // MARK: What the page asks of the browser

    fileprivate func alert(_ message: String, confirm: Bool) async -> Bool {
        guard shown, let window else { return false }
        let alert = NSAlert()
        alert.messageText = title.isEmpty ? (url?.host ?? "") : title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        if confirm { alert.addButton(withTitle: String(localized: "Cancel")) }
        return await withCheckedContinuation { done in
            alert.beginSheetModal(for: window) { done.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    fileprivate func ended(_ failure: Error) {
        guard shown else { return }
        fail(failure.localizedDescription)
    }

    /// Follows the page: how its loads go, what it opens, what it asks.
    fileprivate final class Guide: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
        weak var browser: WebBrowser?
        var failure: Error?

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            failure = nil
            if browser?.failure != nil { browser?.fail(nil) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        private func fail(_ error: Error) {
            let e = error as NSError
            guard e.code != NSURLErrorCancelled, !(e.domain == "WebKitErrorDomain" && e.code == 102) else { return }
            let failure = WebCapture.Failure.load(error.localizedDescription)
            self.failure = failure
            browser?.ended(failure)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            // What would open in a window of its own opens here.
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            // Files to download are left where they are.
            navigationResponse.canShowMIMEType || !navigationResponse.isForMainFrame ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            webView.load(navigationAction.request)
            return nil
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
            _ = await browser?.alert(message, confirm: false)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
            await browser?.alert(message, confirm: true) ?? false
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            fail(WebCapture.Failure.load(String(localized: "the page stopped working.")))
            webView.reload()
        }

        func windowWillClose(_ notification: Notification) {
            browser?.windowClosed()
        }
    }
}

/// The browser's window inside: the bar on top, and the page under it as wide as it is read,
/// as tall as the screen leaves room for; while a page is read, a picture of it held still.
final class BrowserPane: NSView {
    private let bar: NSView
    private let still = NSImageView()

    init(bar: NSView) {
        self.bar = bar
        super.init(frame: .zero)
        addSubview(bar)
        still.imageScaling = .scaleNone
        still.imageAlignment = .alignTopLeft
        still.isHidden = true
        addSubview(still)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// How big the window's inside is for a page read at `size`: as wide, and as tall as the
    /// screen has room for.
    func fitting(_ size: WebCapture.Size) -> CGSize {
        let room = (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 1000
        return CGSize(width: max(size.width, Self.narrowest), height: WebBrowser.barHeight + min(size.height, max(320, room - WebBrowser.barHeight - 40)))
    }

    /// As narrow as the window goes, so the bar has room: a phone's page lies in the middle of it.
    static let narrowest: CGFloat = 760

    func layOut(_ web: WKWebView, size: WebCapture.Size) {
        let inside = fitting(size)
        frame.size = inside
        bar.frame = CGRect(x: 0, y: 0, width: inside.width, height: WebBrowser.barHeight)
        if web.superview !== self {
            web.removeFromSuperview()
            addSubview(web, positioned: .below, relativeTo: still)
        }
        web.frame = CGRect(x: ((inside.width - size.width) / 2).rounded(), y: WebBrowser.barHeight, width: size.width, height: inside.height - WebBrowser.barHeight)
        still.frame = web.frame
    }

    /// Holds a picture of the page in its place.
    func freeze(_ web: WKWebView) async -> Bool {
        guard web.superview === self, let image = try? await web.takeSnapshot(configuration: nil) else { return false }
        still.image = image
        still.frame = web.frame
        still.isHidden = false
        return true
    }

    /// The page back in its place, the picture gone.
    func thaw(_ web: WKWebView, size: WebCapture.Size) {
        layOut(web, size: size)
        still.isHidden = true
        still.image = nil
    }
}

/// The bar over the browser's page: back, forward and again, the address, the size the page is
/// read at, and Import.
struct WebBrowserBar: View {
    @Bindable var browser: WebBrowser
    @FocusState private var typing: Bool

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "chevron.left", help: "Back") { browser.back() }
                .opacity(browser.canGoBack ? 1 : 0.35)
                .allowsHitTesting(browser.canGoBack)
            IconButton(symbol: "chevron.right", help: "Forward") { browser.forward() }
                .opacity(browser.canGoForward ? 1 : 0.35)
                .allowsHitTesting(browser.canGoForward)
            IconButton(symbol: "arrow.clockwise", help: "Reload") { browser.reload() }
                .opacity(browser.url == nil ? 0.35 : 1)
                .allowsHitTesting(browser.url != nil)
            HStack(spacing: 7) {
                Image(systemName: browser.url?.scheme == "https" ? "lock.fill" : "globe")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                TextField(text: $browser.typed, prompt: Text(verbatim: "example.com")) { Text("Address") }
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($typing)
                    .onSubmit { browser.go(browser.typed) }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .well(radius: Theme.controlRadius)
            .padding(.leading, 6)
            PagesButton(browser: browser)
                .padding(.leading, 6)
            HStack(spacing: 2) {
                SizeButton(symbol: "desktopcomputer", help: "Desktop", size: .desktop, browser: browser)
                SizeButton(symbol: "ipad", help: "Tablet", size: .tablet, browser: browser)
                SizeButton(symbol: "iphone", help: "Mobile", size: .mobile, browser: browser)
            }
            .padding(.horizontal, 8)
            PrimaryButton(title: browser.importing ? "Importing…" : browser.justImported ? "Imported" : "Import",
                          progress: browser.progress, enabled: browser.canImport) { browser.importFromWindow() }
                .frame(width: 132)
                .animation(Theme.spring, value: browser.justImported)
        }
        .disabled(browser.importing)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }
}

/// The pages of the site, to choose several and bring them in together.
private struct PagesButton: View {
    let browser: WebBrowser
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Image(systemName: "rectangle.stack")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(open ? Theme.pencil : hovering ? Theme.ink : Theme.ink2)
            .frame(width: 30, height: 28)
            .background {
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(open ? Theme.pencilWash : Theme.ink.opacity(hovering ? 0.06 : 0))
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture {
                guard browser.url != nil else { return }
                open.toggle()
                if open { Task { await browser.findPages() } }
            }
            .opacity(browser.url == nil ? 0.35 : 1)
            .help(Text("Pages"))
            .accessibilityLabel(Text("Pages"))
            .accessibilityAddTraits(.isButton)
            .animation(Theme.quick, value: hovering)
            .popover(isPresented: $open, arrowEdge: .bottom) { PagesList(browser: browser) }
    }
}

/// The pages offered, each to be chosen: the one open, those visited, those it links to; and
/// Import, which brings the chosen ones into one design together.
private struct PagesList: View {
    @Bindable var browser: WebBrowser

    private var count: Int { browser.pages.filter { browser.chosen.contains($0.id) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    group(nil, .open)
                    group("Visited", .visited)
                    group("Links", .linked)
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if browser.importing {
                    Text(verbatim: browser.stage ?? "")
                        .prose(11.5)
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    TextButton(title: "Cancel") { browser.cancelWork() }
                } else {
                    Spacer()
                }
                PrimaryButton(title: "Import \(count) Pages", progress: browser.progress, enabled: count > 0 && !browser.importing) { browser.importChosen() }
                    .frame(width: 176)
            }
        }
        .padding(14)
        .frame(width: 400)
        .background(Theme.paper)
    }

    @ViewBuilder
    private func group(_ title: LocalizedStringResource?, _ kind: WebBrowser.Page.Kind) -> some View {
        let pages = browser.pages.filter { $0.kind == kind }
        if !pages.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                if let title {
                    HStack {
                        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink3)
                        Spacer()
                        let all = pages.allSatisfy { browser.chosen.contains($0.id) }
                        TextButton(title: all ? "None" : "All") {
                            for p in pages { if all { browser.chosen.remove(p.id) } else { browser.chosen.insert(p.id) } }
                        }
                        .disabled(browser.importing)
                    }
                    .padding(.leading, 6)
                }
                ForEach(pages) { page in PageRow(page: page, browser: browser) }
            }
        }
    }
}

private struct PageRow: View {
    let page: WebBrowser.Page
    @Bindable var browser: WebBrowser
    @State private var hovering = false

    var body: some View {
        let on = browser.chosen.contains(page.id)
        HStack(spacing: 9) {
            ZStack {
                if browser.done.contains(page.id) {
                    CheckMark(size: 9, color: Theme.pencil, weight: 1.6)
                } else if browser.reading == page.id {
                    ProgressView().controlSize(.mini)
                } else {
                    CheckBox(isOn: Binding(get: { on }, set: { if $0 { browser.chosen.insert(page.id) } else { browser.chosen.remove(page.id) } }))
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: page.name)
                    .font(.system(size: 12.5, weight: page.kind == .open ? .semibold : .regular))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(verbatim: page.url.isFileURL ? page.url.lastPathComponent : page.url.path + (page.url.query.map { "?" + $0 } ?? ""))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.ink.opacity(hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard !browser.importing else { return }
            if on { browser.chosen.remove(page.id) } else { browser.chosen.insert(page.id) }
        }
        .animation(Theme.quick, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// One of the sizes the browser lays its page out at.
private struct SizeButton: View {
    let symbol: String
    let help: LocalizedStringResource
    let size: WebCapture.Size
    let browser: WebBrowser
    @State private var hovering = false

    var body: some View {
        let on = browser.size.width == size.width
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(on ? Theme.pencil : hovering ? Theme.ink : Theme.ink2)
            .frame(width: 30, height: 28)
            .background {
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(on ? Theme.pencilWash : Theme.ink.opacity(hovering ? 0.06 : 0))
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { if !on { browser.resize(to: size) } }
            .help(Text(help))
            .animation(Theme.quick, value: hovering)
            .accessibilityLabel(Text(help))
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}
