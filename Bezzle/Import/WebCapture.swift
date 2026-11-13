import AppKit
import os
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// Reads web pages: loads each in a web view of its own, out of sight, at the width asked for;
/// has the page reader (WebPageReader.js) take it apart; fetches its pictures; takes its SVG
/// pictures apart into outlines; and photographs what could not be taken apart.
@MainActor
final class WebCapture: NSObject, WKNavigationDelegate {
    /// A width a page is read at, and the height of the window it is read in.
    struct Size: Hashable, Identifiable {
        var name: String
        var width: CGFloat
        var height: CGFloat
        /// Read as a phone reads it, telling the page so.
        var mobile = false

        var id: CGFloat { width }

        static let desktop = Size(name: String(localized: "Desktop"), width: 1440, height: 900)
        static let laptop = Size(name: String(localized: "Laptop"), width: 1280, height: 800)
        static let tablet = Size(name: String(localized: "Tablet"), width: 768, height: 1024)
        static let mobile = Size(name: String(localized: "Mobile"), width: 390, height: 844, mobile: true)
        static let offered: [Size] = [.desktop, .tablet, .mobile]

        /// A width of its own, the window as tall as a screen that wide is.
        static func custom(_ width: CGFloat) -> Size {
            let w = min(max(width.rounded(), 240), 3840)
            return Size(name: String(localized: "\(Int(w)) px"), width: w, height: w <= 500 ? (w * 2.16).rounded() : w <= 1024 ? (w * 1.33).rounded() : (w * 0.625).rounded(), mobile: w <= 500)
        }
    }

    enum Failure: LocalizedError {
        case address
        case load(String)
        case unreadable(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .address: String(localized: "That is not a web address Bezzle can open.")
            case .load(let why): String(localized: "The page could not be loaded: \(why)")
            case .unreadable(let why): String(localized: "The page could not be read: \(why)")
            case .empty: String(localized: "The page shows nothing to bring in.")
            }
        }
    }

    /// Whether cookie banners and the veils they lay over the page are taken away.
    var hideBanners = true
    /// How far down a page is read, at most.
    var maxHeight: CGFloat = 30_000
    /// How long to wait, a screen at a time, for what a page loads as it is scrolled through.
    var stepDelay = 120
    /// Whether a page that scrolls inside a box of its own, as a web app does, is let out to the
    /// full height of what the box holds; otherwise the box stays as it shows, scrolled where it is.
    var unrollsScrollers = true
    /// Says how far it has come: what it is doing, and how much of it is done, 0…1.
    var progress: ((String, Double) -> Void)?
    /// Whether the window the page is read in is put on screen, though no one sees it, so that
    /// the page runs as if it were shown: timers at full speed, and animation frames. Test runs
    /// show no windows.
    var showsWindow = !BezzleApp.isTesting

    private var web: WKWebView?
    private var host: NSWindow?
    /// A web view someone else keeps, read as it is: Bezzle's browser (`WebBrowser`).
    private var adopted = false
    private var finished = false
    private var failure: Error?
    private var status: Int?
    private let world = WKContentWorld.world(name: "BezzleReader")
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    /// Where pages read and browsed keep their cookies and what else they store, apart from
    /// Safari's and from any other app's: a sign-in made in Bezzle's browser holds for the pages
    /// imported after it, and lasts from one launch to the next. Test runs keep nothing.
    static let dataStore: WKWebsiteDataStore = BezzleApp.isTesting
        ? .nonPersistent()
        : WKWebsiteDataStore(forIdentifier: UUID(uuidString: "6D3C2B51-4E8F-4B7A-9C1D-2F5E8A7B0C34")!)

    override init() { super.init() }

    /// Reads the page a web view shows as it is now, without loading it again: what was signed
    /// in to, clicked open and typed stays as it is. The web view is left as it was found.
    init(adopting web: WKWebView) {
        super.init()
        self.web = web
        adopted = true
        finished = true
        unrollsScrollers = false
    }

    static let desktopAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    static let mobileAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    /// The reader, read once from the app.
    static let script = resource("WebPageReader")
    /// What runs in the page before its own scripts, so that what waits to be scrolled to is there.
    static let awake = resource("WebPageAwake")
    /// What records the page's WebGL drawing, before its own scripts, in its own world.
    static let recorder = resource("WebPageGL")

    static func resource(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    /// Makes an address of what was typed: a scheme where it has none, and only web pages and files.
    static func address(_ typed: String) -> URL? {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.contains("://") && !s.hasPrefix("file:") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "file" { return url }
        guard scheme == "http" || scheme == "https", let host = url.host, host.contains(".") || host == "localhost" else { return nil }
        return url
    }

    // MARK: Reading

    /// Reads the page at `url` at one size: what it is made of, and the pictures it shows.
    func read(_ url: URL, size: Size) async throws -> (WebRead, [String: Data]) {
        let web = webView(for: size)
        say(String(localized: "Loading the page…"), 0.02)
        try await load(web) {
            if url.isFileURL { web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) } else { web.load(URLRequest(url: url, timeoutInterval: 30)) }
        }
        return try await take(web, size: size)
    }

    /// Reads a page given as HTML, its addresses taken from `base`.
    func read(html: String, base: URL?, size: Size) async throws -> (WebRead, [String: Data]) {
        let web = webView(for: size)
        try await load(web) { web.loadHTMLString(html, baseURL: base) }
        return try await take(web, size: size)
    }

    /// Reads the page as it is now in the web view adopted, at the size it is laid out at.
    func readAsShown(size: Size) async throws -> (WebRead, [String: Data]) {
        guard let web, adopted else { throw Failure.unreadable(String(localized: "nothing came back.")) }
        status = nil
        return try await take(web, size: size)
    }

    /// Lets go of the web view and its window.
    func close() {
        if adopted {
            web = nil
            return
        }
        web?.stopLoading()
        web?.navigationDelegate = nil
        host?.orderOut(nil)
        host?.contentView = nil
        host?.close()
        host = nil
        web = nil
    }

    private func say(_ what: String, _ done: Double) { progress?(what, min(max(done, 0), 1)) }

    /// A web view laid out at the size, in a window no one sees, so that the page is drawn and
    /// runs as it would on screen.
    private func webView(for size: Size) -> WKWebView {
        let frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let web: WKWebView
        if let existing = self.web {
            web = existing
        } else {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = Self.dataStore
            config.suppressesIncrementalRendering = false
            config.mediaTypesRequiringUserActionForPlayback = .all
            config.preferences.isElementFullscreenEnabled = false
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
            if #available(macOS 14.0, *) { config.preferences.inactiveSchedulingPolicy = .none }
            config.userContentController.addUserScript(WKUserScript(source: Self.awake, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
            config.userContentController.addUserScript(WKUserScript(source: Self.recorder, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
            config.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
            web = WKWebView(frame: frame, configuration: config)
            web.navigationDelegate = self
            self.web = web
        }
        web.customUserAgent = size.mobile ? Self.mobileAgent : Self.desktopAgent
        web.frame = frame
        if host == nil {
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.isExcludedFromWindowsMenu = true
            window.collectionBehavior = [.transient, .ignoresCycle, .stationary, .fullScreenAuxiliary]
            // Above the others, though no one sees it, so the page is not held back as hidden.
            window.level = .floating
            host = window
        }
        if let host {
            host.setContentSize(frame.size)
            if let screen = NSScreen.main { host.setFrameOrigin(CGPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY)) }
            host.contentView = web
            if showsWindow { host.orderFrontRegardless() }
        }
        return web
    }

    /// Starts a page loading and waits until it has: until it says it is done, or, past half a
    /// minute, as soon as it can be read at all.
    private func load(_ web: WKWebView, _ start: () -> Void) async throws {
        finished = false
        failure = nil
        status = nil
        start()
        let begun = Date()
        while !finished {
            if let failure { throw failure }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(80))
            if Date().timeIntervalSince(begun) > 30 {
                let state = try? await web.evaluateJavaScript("document.readyState") as? String
                if state == "interactive" || state == "complete" { break }
                throw Failure.load(String(localized: "it took too long to answer."))
            }
        }
        if let failure { throw failure }
    }

    /// Reads the page loaded: gets it ready, takes it apart, and fetches and photographs what it shows.
    private func take(_ web: WKWebView, size: Size) async throws -> (WebRead, [String: Data]) {
        say(String(localized: "Scrolling through the page…"), 0.15)
        let options: [String: Any] = ["hideBanners": hideBanners, "maxHeight": maxHeight, "stepDelay": stepDelay, "unroll": unrollsScrollers]
        try await ensureReader()
        _ = try await call("return await __bezzle.prepare(opts)", ["opts": options])
        say(String(localized: "Taking the page apart…"), 0.4)
        guard let json = try await call("return await __bezzle.capture(opts)", ["opts": options]) as? String,
              let data = json.data(using: .utf8) else { throw Failure.unreadable(String(localized: "nothing came back.")) }
        let page: WebPage
        do { page = try JSONDecoder().decode(WebPage.self, from: data) } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        guard page.root != nil else { throw Failure.empty }
        var assets = WebAssets()
        var held: [String: Data] = [:]
        try await fetchPictures(page, into: &assets, held: &held)
        await keepScenes(page, into: &assets, held: &held)
        try await photograph(page, into: &assets, held: &held)
        _ = try? await call("__bezzle.finish()", [:])
        var name = size.name
        if let status, status >= 400 { name += " (\(status))" }
        return (WebRead(name: name, page: page, assets: assets), held)
    }

    /// The reader in its world, put there by hand when the page came in before it could be.
    private func ensureReader() async throws {
        guard let web else { return }
        let there = try? await web.callAsyncJavaScript("return typeof __bezzle", arguments: [:], in: nil, contentWorld: world) as? String
        guard there != "object" else { return }
        _ = try await web.evaluateJavaScript(Self.script + "\n;true", in: nil, contentWorld: world)
    }

    /// Calls the reader in its own world, apart from the page's scripts.
    private func call(_ body: String, _ arguments: [String: Any]) async throws -> Any? {
        guard let web else { return nil }
        do {
            return try await web.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: world)
        } catch {
            // The page went on to another, which the reader is in afresh once it has loaded.
            let there = try? await web.callAsyncJavaScript("return typeof __bezzle", arguments: [:], in: nil, contentWorld: world) as? String
            guard there != "object" else { throw error }
            for _ in 0..<150 where !finished { try await Task.sleep(for: .milliseconds(100)) }
            try await ensureReader()
            return try await web.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: world)
        }
    }

    // MARK: Pictures

    /// Fetches the page's pictures: each kept by what it is, SVGs taken apart in the page.
    private func fetchPictures(_ page: WebPage, into assets: inout WebAssets, held: inout [String: Data]) async throws {
        let urls = page.images
        guard !urls.isEmpty else { return }
        let referer = page.url, agent = web?.customUserAgent ?? Self.desktopAgent
        let session = self.session
        // Pictures behind a sign-in come with the cookies the page was read with.
        let cookies = await (web?.configuration.websiteDataStore ?? Self.dataStore).httpCookieStore.allCookies()
        var fetched: [Int: Data] = [:]
        var done = 0
        try await withThrowingTaskGroup(of: (Int, Data?).self) { group in
            var next = 0
            func add() {
                guard next < urls.count else { return }
                let i = next, address = urls[i]
                next += 1
                group.addTask { (i, await Self.fetch(address, session: session, referer: referer, agent: agent, cookies: cookies)) }
            }
            for _ in 0..<8 { add() }
            for try await (i, data) in group {
                if let data { fetched[i] = data }
                done += 1
                say(String(localized: "Bringing in pictures (\(done) of \(urls.count))…"), 0.5 + 0.25 * Double(done) / Double(urls.count))
                try Task.checkCancellation()
                add()
            }
        }
        for (i, data) in fetched.sorted(by: { $0.key < $1.key }) {
            if Self.isSVG(data, url: urls[i]) {
                if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                   let json = try? await call("return __bezzle.vectorize(i, svg)", ["i": i, "svg": text]) as? String,
                   let paths = try? JSONDecoder().decode([WebPath].self, from: Data(json.utf8)), !paths.isEmpty {
                    assets.vectors[i] = paths
                }
                continue
            }
            guard let (ext, pixels) = Importer.picture(data), pixels.width > 0, pixels.height > 0 else { continue }
            let name = Self.assetName(data, ext: ext)
            held[name] = data
            assets.pictures[i] = WebAssets.Picture(asset: name, size: pixels)
        }
    }

    // MARK: WebGL

    /// The scene of each WebGL canvas that draws from its shaders alone (WebPageGL.js), as the
    /// shader fill its layer is drawn with, its pictures fetched; or why it is a picture only.
    private func keepScenes(_ page: WebPage, into assets: inout WebAssets, held: inout [String: Data]) async {
        guard let web, let json = try? await web.callAsyncJavaScript("return window.__bezzleGL ? window.__bezzleGL.scenes() : '{}'", arguments: [:], in: nil, contentWorld: .page) as? String,
              let scenes = try? JSONDecoder().decode([String: WebGLScene].self, from: Data(json.utf8)), !scenes.isEmpty else { return }
        say(String(localized: "Keeping what WebGL draws…"), 0.5)
        let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
        let agent = web.customUserAgent ?? Self.desktopAgent
        for (key, scene) in scenes {
            guard let id = Int(key) else { continue }
            if let why = scene.why {
                if why != "not webgl" && why != "nothing drawn" {
                    assets.stills[id] = why
                    Self.log.notice("A WebGL canvas stays a picture: \(why, privacy: .public)")
                }
                continue
            }
            var textures: [Int: ShaderTexture] = [:]
            var missing = false
            for (pid, picture) in scene.pictures ?? [:] {
                guard let n = Int(pid) else { continue }
                var data: Data?
                if let url = picture.url { data = await Self.fetch(url, session: session, referer: page.url, agent: agent, cookies: cookies) }
                if data == nil, let inline = picture.data { data = Self.dataURL(inline) }
                guard let data, let (ext, pixels) = Importer.picture(data) else { missing = true; continue }
                let name = Self.assetName(data, ext: ext)
                held[name] = data
                textures[n] = ShaderTexture(asset: name, size: pixels)
            }
            if missing {
                assets.stills[id] = "texture"
                Self.log.notice("A WebGL canvas stays a picture: a texture could not be fetched")
                continue
            }
            let fill: ShaderFill
            do { fill = try scene.make(textures: textures) } catch {
                assets.stills[id] = "unreadable"
                Self.log.notice("A WebGL canvas stays a picture: its scene could not be read: \(String(describing: error), privacy: .public)")
                continue
            }
            // Kept only when Bezzle can draw it again.
            let pictures = held.filter { name, _ in textures.values.contains { $0.asset == name } }
            guard ShaderPainting.builds(fill, pictures: pictures) else {
                assets.stills[id] = "does not build"
                Self.log.notice("A WebGL canvas stays a picture: its programs do not build")
                continue
            }
            assets.scenes[id] = fill
        }
    }

    /// What reading a page could not keep, and why: for the person who works on Bezzle.
    nonisolated static let log = Logger(subsystem: "com.erik.Bezzle", category: "WebImport")

    nonisolated static func isSVG(_ data: Data, url: String) -> Bool {
        let head = String(decoding: data.prefix(600), as: UTF8.self).lowercased()
        if head.contains("<svg") { return true }
        if url.lowercased().hasPrefix("data:image/svg") { return true }
        return false
    }

    nonisolated static func assetName(_ data: Data, ext: String) -> String {
        let hash = SHA256.hash(data: data).prefix(10).map { String(format: "%02x", $0) }.joined()
        return "web-\(hash).\(ext)"
    }

    /// A picture by its address: a data: URL read in place, any other fetched as the page would,
    /// with the cookies of its site among `cookies`.
    nonisolated static func fetch(_ address: String, session: URLSession, referer: String, agent: String, cookies: [HTTPCookie] = []) async -> Data? {
        if address.hasPrefix("data:") { return dataURL(address) }
        guard let url = URL(string: address) ?? URL(string: address.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") else { return nil }
        if url.isFileURL { return try? Data(contentsOf: url) }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let sent = Self.cookies(for: url, among: cookies)
        if !sent.isEmpty { HTTPCookie.requestHeaderFields(with: sent).forEach { request.setValue($1, forHTTPHeaderField: $0) } }
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        guard data.count < 40_000_000 else { return nil }
        return data
    }

    /// What a data: URL holds.
    nonisolated static func dataURL(_ s: String) -> Data? {
        guard let comma = s.firstIndex(of: ",") else { return nil }
        let head = s[s.index(s.startIndex, offsetBy: 5)..<comma]
        let body = String(s[s.index(after: comma)...])
        if head.hasSuffix(";base64") { return Data(base64Encoded: body.trimmingCharacters(in: .whitespacesAndNewlines), options: .ignoreUnknownCharacters) }
        return (body.removingPercentEncoding ?? body).data(using: .utf8)
    }

    // MARK: Photographs

    private struct Isolated: Decodable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        var px: Double
        var py: Double
        var sy: Double
        var fixed: Bool
        var vw: Double
        var vh: Double
        var behind: String?
    }

    /// Photographs what Bezzle cannot draw itself, each on white and on black so that what shows
    /// through it can be told from what it is.
    private func photograph(_ page: WebPage, into assets: inout WebAssets, held: inout [String: Data]) async throws {
        // What the GPU draws first, before anything else has been shown alone and it hidden;
        // shown again, a canvas holds nothing until the page draws its next frame.
        let all = WebConverter.photographed(in: page, assets: assets)
        let wanted = Array((all.filter(\.solid) + all.filter { !$0.solid }).prefix(400))
        // A background repeated box after box, alike and as big, is photographed once.
        var items: [Int: WebItem] = [:]
        func index(_ i: WebItem) {
            if i.t == "el", let id = i.id { items[id] = i }
            i.kids?.forEach(index)
        }
        page.root.map(index)
        var alike: [String: WebAssets.Shot] = [:]
        for (k, shot) in wanted.enumerated() {
            try Task.checkCancellation()
            say(String(localized: "Photographing what is not shapes (\(k + 1) of \(wanted.count))…"), 0.75 + 0.22 * Double(k) / Double(max(wanted.count, 1)))
            // Icons alike, unturned, are photographed once, and lie each in its own box.
            let item = items[shot.id]
            let moved = item?.matrix.map { $0.a == 1 && $0.b == 0 && $0.c == 0 && $0.d == 1 } ?? true
            let key = shot.own ? item.map(Self.backgroundKey) : item.flatMap { moved && $0.fixed != true ? $0.key : nil }
            if let key, let done = alike[key] {
                if shot.own {
                    assets.backgrounds[shot.id] = done
                } else if let item {
                    let box = item.matrix.map { item.box.offsetBy(dx: $0.tx, dy: $0.ty) } ?? item.box
                    assets.shots[shot.id] = WebAssets.Shot(asset: done.asset, size: done.size, frame: box.insetBy(dx: -1, dy: -1).integral)
                }
                continue
            }
            let taken: (png: Data, size: CGSize, frame: CGRect)?
            do { taken = try await photograph(shot.id, own: shot.own, solid: shot.solid) } catch is CancellationError { throw CancellationError() } catch { taken = nil }
            _ = try? await call("__bezzle.release()", [:])
            guard let taken else { continue }
            let name = Self.assetName(taken.png, ext: "png")
            held[name] = taken.png
            let picture = WebAssets.Shot(asset: name, size: taken.size, frame: taken.frame)
            if shot.own { assets.backgrounds[shot.id] = picture } else { assets.shots[shot.id] = picture }
            if let key { alike[key] = picture }
        }
        _ = try? await call("__bezzle.release(); window.scrollTo(0, 0)", [:])
    }

    /// What a box's background is made of and how big it is, the same for boxes drawn alike.
    static func backgroundKey(_ i: WebItem) -> String {
        let layers = (i.layers ?? []).map { l in
            [l.img.map(String.init) ?? "", l.grad ?? "", l.other ?? "", l.size ?? "", l.x ?? "", l.y ?? "", l.rep ?? "", l.origin ?? "", l.clip ?? "", l.blend ?? ""].joined(separator: "|")
        }
        let numbers = [i.w ?? 0, i.h ?? 0] + (i.rad ?? []) + (i.ins ?? []) + (i.bg ?? [])
        return layers.joined(separator: ";") + "#" + numbers.map { String(format: "%.1f", $0) }.joined(separator: ",")
    }

    /// One element photographed, as a PNG, its size in pixels, and where on the page it lies:
    /// solid, on the colour behind it, or on nothing.
    private func photograph(_ id: Int, own: Bool, solid: Bool) async throws -> (png: Data, size: CGSize, frame: CGRect)? {
        guard let web, let json = try await call("return __bezzle.isolate(id, own, '#ffffff')", ["id": id, "own": own]) as? String,
              let info = try? JSONDecoder().decode(Isolated.self, from: Data(json.utf8)) else { return nil }
        let page = CGRect(x: info.px, y: info.py, width: info.w, height: info.h).insetBy(dx: -1, dy: -1).integral
        guard page.width >= 2, page.height >= 2 else { return nil }
        let viewport = CGRect(x: 0, y: 0, width: info.vw, height: info.vh)
        // Small things sharp, large ones as they are, and nothing past a few million pixels.
        let area = page.width * page.height
        var scale: CGFloat = area < 300 * 300 ? 3 : area < 1200 * 1200 ? 2 : 1
        // What the GPU draws, a canvas or a video, is photographed as it is on screen: drawn
        // again at another size, a canvas that keeps nothing between frames comes out as noise.
        if solid { scale = 1 }
        while page.width * scale > 4096 || page.height * scale > 8192 { scale /= 2 }
        let pixels = CGSize(width: (page.width * scale).rounded(), height: (page.height * scale).rounded())
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }
        // A screen at a time, for what is taller than the window.
        let tile = max(viewport.height - 40, 100)
        var tops: [CGFloat] = []
        if info.fixed || page.height <= viewport.height {
            tops = [page.minY]
        } else {
            var y = page.minY
            while y < page.maxY && tops.count < 12 { tops.append(y); y += tile }
        }
        func shoot(on color: String) async throws -> CGContext? {
            _ = try await call("__bezzle.matte(c)", ["c": color])
            guard let ctx = Self.context(pixels) else { return nil }
            for top in tops {
                var scrolled = CGFloat(info.sy)
                if !info.fixed && tops.count > 1 {
                    let want = max(0, top - 20)
                    scrolled = CGFloat((try await call("window.scrollTo(0, y); return window.scrollY", ["y": want]) as? Double) ?? Double(want))
                }
                let onScreen = info.fixed ? page : page.offsetBy(dx: 0, dy: -scrolled)
                var part = onScreen.intersection(viewport)
                if tops.count > 1 { part = part.intersection(CGRect(x: onScreen.minX, y: top - scrolled, width: onScreen.width, height: tile)) }
                guard !part.isNull, part.width >= 1, part.height >= 1 else { continue }
                let config = WKSnapshotConfiguration()
                config.rect = part
                if !solid { config.snapshotWidth = NSNumber(value: Double(part.width * scale)) }
                config.afterScreenUpdates = true
                let image = try await web.takeSnapshot(configuration: config)
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                // Where the part lies in the photograph, which is drawn from its bottom left.
                let dx = (part.minX - onScreen.minX) * scale
                let dy = (part.minY - onScreen.minY) * scale
                let dest = CGRect(x: dx, y: pixels.height - dy - part.height * scale, width: part.width * scale, height: part.height * scale)
                ctx.draw(cg, in: dest)
            }
            return ctx
        }
        if solid {
            guard let shot = try await shoot(on: info.behind ?? "#ffffff"), let image = shot.makeImage(), let png = Self.png(image) else { return nil }
            return (png, pixels, page)
        }
        guard let white = try await shoot(on: "#ffffff"), let black = try await shoot(on: "#000000"),
              let png = Self.matted(white: white, black: black) else { return nil }
        return (png, pixels, page)
    }

    /// Whether two photographs of the same thing show it the same, but for a little.
    static func alike(_ a: CGContext, _ b: CGContext) -> Bool {
        guard let pa = a.data, let pb = b.data, a.width == b.width, a.height == b.height, a.width > 0, a.height > 0 else { return false }
        let x = pa.assumingMemoryBound(to: UInt8.self), y = pb.assumingMemoryBound(to: UInt8.self)
        var looked = 0, differ = 0
        for row in stride(from: 0, to: a.height, by: 3) {
            for col in stride(from: 0, to: a.width, by: 3) {
                let i = row * a.bytesPerRow + col * 4, j = row * b.bytesPerRow + col * 4
                looked += 1
                if abs(Int(x[i]) - Int(y[j])) > 40 || abs(Int(x[i + 1]) - Int(y[j + 1])) > 40 || abs(Int(x[i + 2]) - Int(y[j + 2])) > 40 { differ += 1 }
            }
        }
        return Double(differ) / Double(max(looked, 1)) < 0.03
    }

    private static func context(_ size: CGSize) -> CGContext? {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.interpolationQuality = .high
        return ctx
    }

    /// What was photographed on white and on black, as it is on nothing: where the two differ,
    /// what lies behind shows through it, and by how much. Something that moved between the two,
    /// which no picture lying still can explain, is kept as it was on white, solid.
    static func matted(white: CGContext, black: CGContext) -> Data? {
        guard let w = white.data, let b = black.data, white.width == black.width, white.height == black.height else { return nil }
        let width = white.width, height = white.height
        let wRow = white.bytesPerRow, bRow = black.bytesPerRow
        guard let out = context(CGSize(width: width, height: height)), let o = out.data else { return nil }
        let oRow = out.bytesPerRow
        let wp = w.assumingMemoryBound(to: UInt8.self), bp = b.assumingMemoryBound(to: UInt8.self), op = o.assumingMemoryBound(to: UInt8.self)
        var any = false
        var shot = 0, impossible = 0
        for y in 0..<height {
            for x in 0..<width {
                let wi = y * wRow + x * 4, bi = y * bRow + x * 4
                guard wp[wi + 3] != 0 || bp[bi + 3] != 0 else { continue }
                shot += 1
                // On black, nothing lying still is lighter than on white, nor differs by channel.
                let dr = Int(wp[wi]) - Int(bp[bi]), dg = Int(wp[wi + 1]) - Int(bp[bi + 1]), db = Int(wp[wi + 2]) - Int(bp[bi + 2])
                if min(dr, dg, db) < -12 || max(dr, dg, db) - min(dr, dg, db) > 40 { impossible += 1 }
            }
        }
        if shot > 0, Double(impossible) / Double(shot) > 0.01 {
            guard let image = white.makeImage() else { return nil }
            return png(image)
        }
        for y in 0..<height {
            for x in 0..<width {
                let wi = y * wRow + x * 4, bi = y * bRow + x * 4, oi = y * oRow + x * 4
                // Unshot pixels are clear in both.
                if wp[wi + 3] == 0 && bp[bi + 3] == 0 { continue }
                let dr = Int(wp[wi]) - Int(bp[bi]), dg = Int(wp[wi + 1]) - Int(bp[bi + 1]), db = Int(wp[wi + 2]) - Int(bp[bi + 2])
                let alpha = max(0, min(255, 255 - (dr + dg + db) / 3))
                guard alpha > 0 else { continue }
                any = true
                // Premultiplied, the colour on black is the colour times its alpha.
                op[oi] = bp[bi]
                op[oi + 1] = bp[bi + 1]
                op[oi + 2] = bp[bi + 2]
                op[oi + 3] = UInt8(alpha)
                op[oi] = min(op[oi], UInt8(alpha))
                op[oi + 1] = min(op[oi + 1], UInt8(alpha))
                op[oi + 2] = min(op[oi + 2], UInt8(alpha))
            }
        }
        guard any, let image = out.makeImage() else { return nil }
        return png(image)
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        finished = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        failure = Failure.load(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        // A frame load interrupted by a download or a redirect handled elsewhere is no failure.
        if (error as NSError).domain == "WebKitErrorDomain", (error as NSError).code == 102 { return }
        failure = Failure.load(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse { status = http.statusCode }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Pages that open others leave them unopened.
        navigationAction.targetFrame == nil ? .cancel : .allow
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failure = Failure.load(String(localized: "the page stopped working."))
    }
}

/// Brings a web page in as a new design: read at each size asked for, an artboard a size.
@MainActor
enum WebImport {
    /// Reads the page and writes the design in `folder`. Says where it is and what came across.
    static func run(_ url: URL, sizes: [WebCapture.Size], hideBanners: Bool = true, into folder: URL,
                    progress: ((String, Double) -> Void)? = nil) async throws -> (URL, ImportReport) {
        let (reads, held) = try await read(url, sizes: sizes, hideBanners: hideBanners, progress: progress)
        progress?(String(localized: "Laying out the layers…"), 0.96)
        try Task.checkCancellation()
        return try write(reads, held: held, source: source(of: url), into: folder)
    }

    /// Reads the page and brings it into a design that is open, beside what is there, an
    /// artboard a size, each named for the page. Says which they are and what came across.
    static func run(_ url: URL, sizes: [WebCapture.Size], hideBanners: Bool = true, into store: DocumentStore, named name: String? = nil,
                    progress: ((String, Double) -> Void)? = nil) async throws -> (ids: [UUID], report: ImportReport) {
        var (reads, held) = try await read(url, sizes: sizes, hideBanners: hideBanners, progress: progress)
        progress?(String(localized: "Laying out the layers…"), 0.96)
        try Task.checkCancellation()
        var named = store.doc.nodes
        for i in reads.indices {
            let size = sizes.isEmpty ? WebCapture.Size.desktop : sizes[i]
            let given = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            reads[i].name = !given.isEmpty && reads.count == 1 ? given : WebImport.boardName(of: reads[i].page, size: size, among: named)
            named.append(Node(kind: .artboard, name: reads[i].name, frame: .zero))
        }
        return try store.bringIn(reads, held: held, source: source(of: url))
    }

    /// Reads the page at each size asked for, a desktop's when none is: what each is made of,
    /// and the pictures they show.
    static func read(_ url: URL, sizes: [WebCapture.Size], hideBanners: Bool = true,
                     progress: ((String, Double) -> Void)? = nil) async throws -> ([WebRead], [String: Data]) {
        let capture = WebCapture()
        capture.hideBanners = hideBanners
        defer { capture.close() }
        var reads: [WebRead] = []
        var held: [String: Data] = [:]
        let sizes = sizes.isEmpty ? [WebCapture.Size.desktop] : sizes
        for (i, size) in sizes.enumerated() {
            capture.progress = { what, done in
                let lead = sizes.count > 1 ? "\(size.name): " : ""
                progress?(lead + what, (Double(i) + done) / Double(sizes.count) * 0.95)
            }
            let (read, pictures) = try await capture.read(url, size: size)
            reads.append(read)
            held.merge(pictures) { a, _ in a }
        }
        return (reads, held)
    }

    /// The design made of what was read, written as a new design in `folder`.
    static func write(_ reads: [WebRead], held: [String: Data], source: String, into folder: URL) throws -> (URL, ImportReport) {
        let (doc, report) = WebConverter.document(reads, source: source)
        guard !doc.nodes.isEmpty else { throw WebCapture.Failure.empty }
        let imported = Imported(document: doc, report: report, archive: nil, held: held)
        return try Importer.write(imported, named: name(of: reads.first?.page, source: source), into: folder)
    }

    /// What the web site is called, as it is named in the report: its host without "www.".
    static func source(of url: URL) -> String {
        if url.isFileURL { return url.deletingPathExtension().lastPathComponent }
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The design's name: the page's title, or else the site's.
    static func name(of page: WebPage?, source: String) -> String {
        var title = (page?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ",")
        title = title.components(separatedBy: .newlines).joined(separator: " ")
        if title.count > 60 { title = String(title.prefix(60)).trimmingCharacters(in: .whitespaces) + "…" }
        return title.isEmpty ? source : title
    }
}
