import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CBezzleHost

// From Bezzle/Import/WebCapture.swift, for Windows: the page is read in WebView2, Microsoft Edge's
// engine, which Windows 11 has (CBezzleHost/webview.cpp), where the Mac reads it in a WKWebView.
// The rest is the Mac's: the same sizes, the same reader and what runs before the page's scripts
// (WebPageReader.js and WebPageAwake.js, linked from Bezzle/Import and built into the core), the
// same waiting, pictures and photographs, and the same failures. Where WebKit is asked something,
// WebView2's DevTools protocol is: the reader runs in a world of its own as on the Mac
// (Page.createIsolatedWorld), is called as WebKit calls it (Runtime.callFunctionOn, awaited), and
// what is photographed is taken as WebKit takes snapshots (Page.captureScreenshot).

/// Reads web pages: loads each in a web view of its own, out of sight, at the width asked for;
/// has the page reader (WebPageReader.js) take it apart; fetches its pictures; takes its SVG
/// pictures apart into outlines; and photographs what could not be taken apart.
@MainActor
final class WebCapture {
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
        /// What the page's hands said went wrong (WebPageHands.js), as they said it.
        case said(String)

        var errorDescription: String? {
            switch self {
            case .address: String(localized: "That is not a web address Bezzle can open.")
            case .load(let why): String(localized: "The page could not be loaded: \(why)")
            case .unreadable(let why): String(localized: "The page could not be read: \(why)")
            case .empty: String(localized: "The page shows nothing to bring in.")
            case .said(let what): what
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
    /// How many of the screen's pixels a CSS pixel is drawn with: the screen's, as the Mac's window
    /// is drawn at its screen's (0), or another (BEZZLE_WEB_SCALE, for comparing with a Mac).
    var scale: Double = ProcessInfo.processInfo.environment["BEZZLE_WEB_SCALE"].flatMap(Double.init) ?? 0
    /// Told why a WebGL canvas stays a picture, for the person who works on Bezzle (the Mac's
    /// Logger in category WebImport); the app sends it to its trace.
    nonisolated(unsafe) static var log: (String) -> Void = { _ in }

    private(set) var view: Int32 = 0
    /// A web view someone else keeps, read as it is: Bezzle's browser (`WebBrowser`).
    private var adopted = false
    private var status: Int?
    /// The reader's world in the page loaded, and how many loads had begun when it was made.
    private var world: (context: Int, navigations: Int32)?
    /// How many of a snapshot's pixels WebView2 gives for each asked for (its device pixels).
    private var snapshotRatio: CGFloat = 1
    private var snapshotMeasured = false
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    /// Edge's own, as the Mac's is Safari's (empty: WebView2's).
    static let desktopAgent = ""
    static let mobileAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    init() {}

    /// Reads the page a web view shows as it is now, without loading it again: what was signed
    /// in to, clicked open and typed stays as it is. The web view is left as it was found.
    init(adopting view: Int32) {
        self.view = view
        adopted = true
        unrollsScrollers = false
    }

    /// The reader, built into the core from the Mac's file.
    static let script = String(decoding: PackageResources.WebPageReader_js, as: UTF8.self)
    /// What runs in the page before its own scripts, so that what waits to be scrolled to is
    /// there: in the page itself only, not in the frames it holds, as on the Mac.
    static let awake = topFrame(PackageResources.WebPageAwake_js)
    /// What records the page's WebGL drawing, before its own scripts, in its own world, as on the Mac.
    static let recorder = topFrame(PackageResources.WebPageGL_js)
    /// What a page read is given before its scripts: both of them.
    static let atStart = awake + "\n" + recorder
    /// Bezzle's hands in a page (WebPageHands.js), for an assistant browsing (`WebBrowser`).
    static let handsScript = String(decoding: PackageResources.WebPageHands_js, as: UTF8.self)

    /// A script the Mac gives the main frame alone, as WebView2 gives scripts to every frame.
    private static func topFrame(_ bytes: [UInt8]) -> String {
        "if (window === window.top) {\n" + String(decoding: bytes, as: UTF8.self) + "\n}"
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
        // WebView2 says only that something went wrong where WebKit says the file is not there.
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
            throw Failure.load(String(localized: "There is no such file."))
        }
        try await webView(for: size)
        say(String(localized: "Loading the page…"), 0.02)
        try await load(url.absoluteString, html: false)
        return try await take(size: size)
    }

    /// Reads a page given as HTML. WebView2 shows a page given so at no address of its own, so
    /// `base` is not used here.
    func read(html: String, base: URL?, size: Size) async throws -> (WebRead, [String: Data]) {
        try await webView(for: size)
        try await load(html, html: true)
        return try await take(size: size)
    }

    /// Reads the page as it is now in the web view adopted, at the size it is laid out at.
    func readAsShown(size: Size) async throws -> (WebRead, [String: Data]) {
        guard view != 0, adopted else { throw Failure.unreadable(String(localized: "nothing came back.")) }
        status = nil
        return try await take(size: size)
    }

    /// Lets go of the web view and its window; one adopted stays as it is, its keeper's.
    func close() {
        let v = view
        view = 0
        world = nil
        guard v != 0, !adopted else { return }
        DispatchQueue.global(qos: .utility).async { bz_web_close(v) }
    }

    /// Calls Bezzle's hands (WebPageHands.js) in the reader's world, putting them there first when
    /// the page came in before they could be: what `body` returns, or what the page said went
    /// wrong, in its own words.
    func hands(_ body: String, _ arguments: [String: Any]) async throws -> Any? {
        let there = try? await callInWorld("return typeof __bezzleHands", [:]) as? String
        if there != "object" { _ = try? await evaluate(Self.handsScript + "\n;true", inWorld: true) }
        do {
            return try await callInWorld(body, arguments)
        } catch Failure.unreadable(let what) {
            // A thrown Error is described with where it was thrown: its first line, without "Error: ".
            let first = what.components(separatedBy: .newlines).first ?? what
            throw Failure.said(first.hasPrefix("Error: ") ? String(first.dropFirst(7)) : first)
        }
    }

    /// Evaluates an expression in the page's own world, where its scripts run: what it gives.
    func inPage(_ expression: String) async throws -> Any? {
        try await evaluate(expression, inWorld: false)
    }

    /// Asks WebView2's DevTools protocol of the page (`method` with `params`): its answer.
    func ask(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        try await send(method, params)
    }

    private func say(_ what: String, _ done: Double) { progress?(what, min(max(done, 0), 1)) }

    /// A web view laid out at the size, in a window no one sees, so that the page is drawn and
    /// runs as it would on screen.
    private func webView(for size: Size) async throws {
        let agent = size.mobile ? Self.mobileAgent : Self.desktopAgent
        let width = Int32(size.width), height = Int32(size.height)
        if view == 0 {
            let scale = self.scale, awake = Self.atStart
            let made = await Self.off { bz_web_open(width, height, scale, agent, awake) }
            guard made != 0 else {
                let why = await Self.off { () -> String in
                    let text = bz_web_error()
                    defer { bz_web_free(text) }
                    return text.map { String(cString: $0) } ?? ""
                }
                throw Failure.load(why)
            }
            view = made
        } else {
            let v = view
            _ = await Self.off { bz_web_resize(v, width, height, agent) }
        }
    }

    /// How loading goes: 0 loading, 1 loaded, 2 failed, 3 the page stopped working.
    private func state() -> (state: Int32, status: Int32, error: Int32, navigations: Int32) {
        var status: Int32 = 0, error: Int32 = 0, navigations: Int32 = 0
        let state = bz_web_state(view, &status, &error, &navigations)
        return (state, status, error, navigations)
    }

    private var finished: Bool { state().state == 1 }

    /// Starts a page loading and waits until it has: until it says it is done, or, past half a
    /// minute, as soon as it can be read at all.
    private func load(_ text: String, html: Bool) async throws {
        status = nil
        world = nil
        let v = view
        _ = await Self.off { bz_web_load(v, text, html ? 1 : 0) }
        let begun = Date()
        while true {
            let now = state()
            if now.status > 0 { status = Int(now.status) }
            if now.state == 1 { break }
            if now.state == 2 { throw Failure.load(Self.why(now.error)) }
            if now.state == 3 { throw Failure.load(String(localized: "the page stopped working.")) }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(80))
            if Date().timeIntervalSince(begun) > 30 {
                let state = (try? await evaluate("document.readyState", inWorld: false)) as? String
                if state == "interactive" || state == "complete" { break }
                throw Failure.load(String(localized: "it took too long to answer."))
            }
        }
    }

    /// Why a page could not be loaded, as bz_web_state says it, in the words the Mac's system says
    /// it in.
    static func why(_ error: Int32) -> String {
        switch error {
        case 1: String(localized: "The certificate for this server is invalid.")
        case 2: String(localized: "The network connection was lost.")
        case 3: String(localized: "The Internet connection appears to be offline.")
        case 4: String(localized: "Could not connect to the server.")
        case 5: String(localized: "A server with the specified hostname could not be found.")
        case 6: String(localized: "There were too many redirects.")
        case 7: String(localized: "The page asks for a password.")
        case 8: String(localized: "The request timed out.")
        default: String(localized: "An unknown error occurred.")
        }
    }

    /// Reads the page loaded: gets it ready, takes it apart, and fetches and photographs what it shows.
    private func take(size: Size) async throws -> (WebRead, [String: Data]) {
        say(String(localized: "Scrolling through the page…"), 0.15)
        let options: [String: Any] = ["hideBanners": hideBanners, "maxHeight": Double(maxHeight), "stepDelay": stepDelay, "unroll": unrollsScrollers]
        try await ensureReader()
        _ = try await call("return await __bezzle.prepare(opts)", ["opts": options])
        say(String(localized: "Taking the page apart…"), 0.4)
        guard let json = try await call("return await __bezzle.capture(opts)", ["opts": options]) as? String,
              let data = json.data(using: .utf8) else { throw Failure.unreadable(String(localized: "nothing came back.")) }
        var page: WebPage
        do { page = try JSONDecoder().decode(WebPage.self, from: data) } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        guard let root = page.root else { throw Failure.empty }
        page.root = Self.clippedAsInWebKit(root)
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

    /// Edge's own style sheet cuts pictures, videos and canvases off at their boxes (overflow:
    /// clip), where Safari's lets them be: what they show is in their box either way, so they are
    /// read as unclipped, as on the Mac, and come in as pictures with their corners rather than
    /// as masks.
    nonisolated static func clippedAsInWebKit(_ item: WebItem) -> WebItem {
        var item = item
        if item.clip == true, ["img", "video", "canvas"].contains(item.tag ?? ""), item.kids?.isEmpty ?? true { item.clip = nil }
        item.kids = item.kids?.map(clippedAsInWebKit)
        return item
    }

    // MARK: The page's scripts

    /// The reader's world in the page loaded, made again when another page has come in.
    private func readerWorld() async throws -> Int {
        let navigations = state().navigations
        if let world, world.navigations == navigations { return world.context }
        let tree = try await send("Page.getFrameTree", [:])
        guard let frame = (tree["frameTree"] as? [String: Any])?["frame"] as? [String: Any], let id = frame["id"] as? String else {
            throw Failure.unreadable(String(localized: "nothing came back."))
        }
        let made = try await send("Page.createIsolatedWorld", ["frameId": id, "worldName": "BezzleReader"])
        guard let context = Self.number(made["executionContextId"]) else { throw Failure.unreadable(String(localized: "nothing came back.")) }
        world = (Int(context), navigations)
        return Int(context)
    }

    /// The reader in its world, put there when the page has come in.
    private func ensureReader() async throws {
        let there = try? await callInWorld("return typeof __bezzle", [:]) as? String
        guard there != "object" else { return }
        _ = try await evaluate(Self.script + "\n;true", inWorld: true)
    }

    /// Calls the reader in its own world, apart from the page's scripts.
    private func call(_ body: String, _ arguments: [String: Any]) async throws -> Any? {
        do {
            return try await callInWorld(body, arguments)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The page went on to another, which the reader is in afresh once it has loaded.
            world = nil
            let there = try? await callInWorld("return typeof __bezzle", [:]) as? String
            guard there != "object" else { throw error }
            for _ in 0..<150 where !finished { try await Task.sleep(for: .milliseconds(100)) }
            try await ensureReader()
            return try await callInWorld(body, arguments)
        }
    }

    /// `body` as the body of an async function in the reader's world, given `arguments` by name,
    /// awaited, as WebKit's callAsyncJavaScript runs it; what it returns, as JSON gives it.
    private func callInWorld(_ body: String, _ arguments: [String: Any]) async throws -> Any? {
        let context = try await readerWorld()
        let names = arguments.keys.sorted()
        let function = "async function(\(names.joined(separator: ", "))) {\n\(body)\n}"
        let answer = try await send("Runtime.callFunctionOn", [
            "functionDeclaration": function, "executionContextId": context, "arguments": names.map { ["value": arguments[$0]!] },
            "awaitPromise": true, "returnByValue": true,
        ], timeout: 900_000)
        return try Self.value(answer)
    }

    /// An expression evaluated in the reader's world or the page's own.
    private func evaluate(_ expression: String, inWorld: Bool) async throws -> Any? {
        var params: [String: Any] = ["expression": expression, "returnByValue": true, "awaitPromise": true]
        if inWorld { params["contextId"] = try await readerWorld() }
        return try Self.value(try await send("Runtime.evaluate", params, timeout: 120_000))
    }

    private static func value(_ answer: [String: Any]) throws -> Any? {
        if let thrown = answer["exceptionDetails"] as? [String: Any] {
            let what = ((thrown["exception"] as? [String: Any])?["description"] as? String) ?? (thrown["text"] as? String) ?? ""
            throw Failure.unreadable(what)
        }
        guard let result = answer["result"] as? [String: Any], result["type"] as? String != "undefined" else { return nil }
        let value = result["value"]
        return value is NSNull ? nil : value
    }

    /// Asks WebView2's DevTools protocol, away from the main thread, and answers its result.
    private func send(_ method: String, _ params: [String: Any], timeout: Int32 = 60_000) async throws -> [String: Any] {
        let v = view
        guard v != 0 else { throw Failure.load(String(localized: "the page stopped working.")) }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self)
        let (code, text) = await Self.off { () -> (Int32, String) in
            var answer: UnsafeMutablePointer<CChar>?
            let code = bz_web_call(v, method, json, timeout, &answer)
            defer { bz_web_free(answer) }
            return (code, answer.map { String(cString: $0) } ?? "")
        }
        let object = ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]) ?? [:]
        guard code == 0 else {
            if state().state == 3 { throw Failure.load(String(localized: "the page stopped working.")) }
            throw Failure.unreadable((object["message"] as? String) ?? text)
        }
        return object
    }

    /// Runs `work`, which waits for WebView2, on a thread of its own, not the main one.
    nonisolated private static func off<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: work()) }
        }
    }

    nonisolated static func number(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: d
        case let i as Int: Double(i)
        case let n as NSNumber: n.doubleValue
        default: nil
        }
    }

    // MARK: Pictures

    /// Fetches the page's pictures: each kept by what it is, SVGs taken apart in the page.
    private func fetchPictures(_ page: WebPage, into assets: inout WebAssets, held: inout [String: Data]) async throws {
        let urls = page.images
        guard !urls.isEmpty else { return }
        let referer = page.url
        let agent = ((try? await call("return navigator.userAgent", [:])) as? String) ?? ""
        let session = self.session
        // Pictures behind a sign-in come with the cookies the page was read with.
        let cookies = await self.cookies()
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

    // MARK: WebGL

    /// The scene of each WebGL canvas that draws from its shaders alone (WebPageGL.js), as the
    /// shader fill its layer is drawn with, its pictures fetched; or why it is a picture only.
    private func keepScenes(_ page: WebPage, into assets: inout WebAssets, held: inout [String: Data]) async {
        guard let json = try? await evaluate("window.__bezzleGL ? window.__bezzleGL.scenes() : '{}'", inWorld: false) as? String,
              let scenes = try? JSONDecoder().decode([String: WebGLScene].self, from: Data(json.utf8)), !scenes.isEmpty else { return }
        say(String(localized: "Keeping what WebGL draws…"), 0.5)
        let cookies = await self.cookies()
        let agent = ((try? await call("return navigator.userAgent", [:])) as? String) ?? ""
        for (key, scene) in scenes {
            guard let id = Int(key) else { continue }
            if let why = scene.why {
                if why != "not webgl" && why != "nothing drawn" {
                    assets.stills[id] = why
                    Self.log("A WebGL canvas stays a picture: \(why)")
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
                Self.log("A WebGL canvas stays a picture: a texture could not be fetched")
                continue
            }
            let fill: ShaderFill
            do { fill = try scene.make(textures: textures) } catch {
                assets.stills[id] = "unreadable"
                Self.log("A WebGL canvas stays a picture: its scene could not be read: \(error)")
                continue
            }
            // Kept only when Bezzle can draw it again.
            let pictures = held.filter { name, _ in textures.values.contains { $0.asset == name } }
            guard ShaderPainting.builds(fill, pictures: pictures) else {
                assets.stills[id] = "does not build"
                Self.log("A WebGL canvas stays a picture: its programs do not build")
                continue
            }
            assets.scenes[id] = fill
        }
    }

    // MARK: Cookies

    /// Every cookie the page's profile keeps, as WebView2's DevTools protocol lists them.
    private func cookies() async -> [HTTPCookie] {
        guard let answer = try? await send("Network.getAllCookies", [:]), let list = answer["cookies"] as? [[String: Any]] else { return [] }
        return list.compactMap(Self.cookie)
    }

    /// A cookie as the DevTools protocol describes it: its domain with a dot when it holds for the
    /// hosts in it, as Foundation's are.
    nonisolated static func cookie(_ c: [String: Any]) -> HTTPCookie? {
        guard let name = c["name"] as? String, let value = c["value"] as? String, let domain = c["domain"] as? String else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: (c["path"] as? String) ?? "/"]
        if c["secure"] as? Bool == true { properties[.secure] = "TRUE" }
        if let expires = number(c["expires"]), expires > 0, c["session"] as? Bool != true {
            properties[.expires] = Date(timeIntervalSince1970: expires)
        }
        return HTTPCookie(properties: properties)
    }

    /// A picture by its address: a data: URL read in place, any other fetched as the page would,
    /// with the cookies of its site among `cookies`. Pictures in AVIF are not asked for, as the Mac
    /// asks for them first: Bezzle cannot draw them on Windows.
    nonisolated static func fetch(_ address: String, session: URLSession, referer: String, agent: String, cookies: [HTTPCookie] = []) async -> Data? {
        if address.hasPrefix("data:") { return dataURL(address) }
        guard let url = URL(string: address) ?? URL(string: address.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") else { return nil }
        if url.isFileURL { return try? Data(contentsOf: url) }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        if !agent.isEmpty { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("image/webp,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
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

    /// Pixels as a bitmap context of the Mac's keeps them: premultiplied RGBA, rows top first.
    nonisolated struct Photo: Sendable {
        var width: Int
        var height: Int
        var bytes: [UInt8]

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            bytes = [UInt8](repeating: 0, count: width * height * 4)
        }

        init(width: Int, height: Int, bytes: [UInt8]) {
            self.width = width
            self.height = height
            self.bytes = bytes
        }

        /// A PNG file's or a JPEG's pixels, as Skia reads them.
        static func decoded(_ data: Data) -> Photo? {
            var w: Int32 = 0, h: Int32 = 0
            guard data.withUnsafeBytes({ bz_image_pixel_size($0.baseAddress, Int64($0.count), &w, &h) }) != 0, w > 0, h > 0 else { return nil }
            var photo = Photo(width: Int(w), height: Int(h))
            let read = data.withUnsafeBytes { source in
                photo.bytes.withUnsafeMutableBytes { bz_image_decode(source.baseAddress, Int64(source.count), w, h, $0.baseAddress) }
            }
            return read == 0 ? photo : nil
        }

        /// Another photo drawn into `dest` (in this one's pixels), over what is there, as the Mac
        /// draws a snapshot: scaled to fit where its size is not the place's.
        mutating func draw(_ other: Photo, in dest: CGRect) {
            let x0 = Int(dest.minX.rounded()), y0 = Int(dest.minY.rounded())
            let w = max(Int(dest.width.rounded()), 1), h = max(Int(dest.height.rounded()), 1)
            let width = self.width, height = self.height
            other.bytes.withUnsafeBufferPointer { src in
                bytes.withUnsafeMutableBufferPointer { out in
                    for y in 0..<h {
                        let ty = y0 + y
                        guard ty >= 0, ty < height else { continue }
                        let sy0 = y * other.height / h, sy1 = max((y + 1) * other.height / h, sy0 + 1)
                        for x in 0..<w {
                            let tx = x0 + x
                            guard tx >= 0, tx < width else { continue }
                            let sx0 = x * other.width / w, sx1 = max((x + 1) * other.width / w, sx0 + 1)
                            // The source pixels this one covers, averaged (one, where the sizes agree).
                            var sum = (0, 0, 0, 0), count = 0
                            for sy in sy0..<min(sy1, other.height) {
                                for sx in sx0..<min(sx1, other.width) {
                                    let k = (sy * other.width + sx) * 4
                                    sum.0 += Int(src[k]); sum.1 += Int(src[k + 1]); sum.2 += Int(src[k + 2]); sum.3 += Int(src[k + 3])
                                    count += 1
                                }
                            }
                            guard count > 0 else { continue }
                            let a = sum.3 / count
                            let o = (ty * width + tx) * 4
                            // Source over what is there, premultiplied.
                            let keep = 255 - a
                            out[o] = UInt8(min(255, sum.0 / count + Int(out[o]) * keep / 255))
                            out[o + 1] = UInt8(min(255, sum.1 / count + Int(out[o + 1]) * keep / 255))
                            out[o + 2] = UInt8(min(255, sum.2 / count + Int(out[o + 2]) * keep / 255))
                            out[o + 3] = UInt8(min(255, a + Int(out[o + 3]) * keep / 255))
                        }
                    }
                }
            }
        }

        /// As a PNG file's bytes.
        func png() -> Data? {
            var capacity = Int64(width * height * 4 + 4096)
            for _ in 0..<2 {
                var out = [UInt8](repeating: 0, count: Int(capacity))
                let written = bytes.withUnsafeBytes { pixels in
                    out.withUnsafeMutableBytes { bz_png_encode(Int32(width), Int32(height), pixels.baseAddress, 0, $0.baseAddress, capacity) }
                }
                if written > 0 { return Data(out.prefix(Int(written))) }
                guard written < 0, -written > capacity else { return nil }
                capacity = -written
            }
            return nil
        }
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
        guard view != 0, let json = try await call("return __bezzle.isolate(id, own, '#ffffff')", ["id": id, "own": own]) as? String,
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
        func shoot(on color: String) async throws -> Photo? {
            _ = try await call("__bezzle.matte(c)", ["c": color])
            var photo = Photo(width: Int(pixels.width), height: Int(pixels.height))
            for top in tops {
                var scrolled = CGFloat(info.sy)
                if !info.fixed && tops.count > 1 {
                    let want = max(0, top - 20)
                    scrolled = CGFloat(Self.number(try await call("window.scrollTo(0, y); return window.scrollY", ["y": Double(want)])) ?? Double(want))
                }
                let onScreen = info.fixed ? page : page.offsetBy(dx: 0, dy: -scrolled)
                var part = onScreen.intersection(viewport)
                if tops.count > 1 { part = part.intersection(CGRect(x: onScreen.minX, y: top - scrolled, width: onScreen.width, height: tile)) }
                guard !part.isNull, part.width >= 1, part.height >= 1 else { continue }
                guard let image = try await snapshot(part, scrolled: scrolled, scale: scale) else { continue }
                // Where the part lies in the photograph, from its top left.
                let dx = (part.minX - onScreen.minX) * scale
                let dy = (part.minY - onScreen.minY) * scale
                photo.draw(image, in: CGRect(x: dx, y: dy, width: part.width * scale, height: part.height * scale))
            }
            return photo
        }
        if solid {
            guard let shot = try await shoot(on: info.behind ?? "#ffffff") else { return nil }
            guard let png = await Self.off({ shot.png() }) else { return nil }
            return (png, pixels, page)
        }
        guard let white = try await shoot(on: "#ffffff"), let black = try await shoot(on: "#000000") else { return nil }
        guard let png = await Self.off({ Self.matted(white: white, black: black) }) else { return nil }
        return (png, pixels, page)
    }

    /// The part of the window `part` (scrolled by `scrolled`) as the page shows it, `scale` pixels
    /// to a CSS pixel, as WebKit's snapshots take it after the screen has been updated.
    private func snapshot(_ part: CGRect, scrolled: CGFloat, scale: CGFloat) async throws -> Photo? {
        // Measured in the page, from its top: the window's place in it, and the part's in that.
        let clip: [String: Any] = ["x": Double(part.minX), "y": Double(part.minY + scrolled), "width": Double(part.width), "height": Double(part.height),
                                   "scale": Double(scale / snapshotRatio)]
        let answer = try await send("Page.captureScreenshot", ["format": "png", "clip": clip, "fromSurface": true, "captureBeyondViewport": false])
        guard let encoded = answer["data"] as? String, let data = Data(base64Encoded: encoded) else { return nil }
        let photo = await Self.off { Photo.decoded(data) }
        // WebView2 gives its device pixels: once measured, asked for as many as are wanted.
        if let photo, !snapshotMeasured, part.width >= 40 {
            let ratio = CGFloat(photo.width) / (part.width * scale / snapshotRatio)
            snapshotRatio = (ratio * 100).rounded() / 100
            snapshotMeasured = true
        }
        return photo
    }

    /// What was photographed on white and on black, as it is on nothing: where the two differ,
    /// what lies behind shows through it, and by how much. Something that moved between the two,
    /// which no picture lying still can explain, is kept as it was on white, solid.
    nonisolated static func matted(white: Photo, black: Photo) -> Data? {
        guard white.width == black.width, white.height == black.height else { return nil }
        let count = white.width * white.height
        var out = Photo(width: white.width, height: white.height)
        var any = false
        var shot = 0, impossible = 0
        let solid: Bool = white.bytes.withUnsafeBufferPointer { wp in
            black.bytes.withUnsafeBufferPointer { bp in
                for i in 0..<count {
                    let k = i * 4
                    guard wp[k + 3] != 0 || bp[k + 3] != 0 else { continue }
                    shot += 1
                    // On black, nothing lying still is lighter than on white, nor differs by channel.
                    let dr = Int(wp[k]) - Int(bp[k]), dg = Int(wp[k + 1]) - Int(bp[k + 1]), db = Int(wp[k + 2]) - Int(bp[k + 2])
                    if min(dr, dg, db) < -12 || max(dr, dg, db) - min(dr, dg, db) > 40 { impossible += 1 }
                }
                return shot > 0 && Double(impossible) / Double(shot) > 0.01
            }
        }
        if solid { return white.png() }
        white.bytes.withUnsafeBufferPointer { wp in
            black.bytes.withUnsafeBufferPointer { bp in
                out.bytes.withUnsafeMutableBufferPointer { op in
                    for i in 0..<count {
                        let k = i * 4
                        // Unshot pixels are clear in both.
                        if wp[k + 3] == 0 && bp[k + 3] == 0 { continue }
                        let dr = Int(wp[k]) - Int(bp[k]), dg = Int(wp[k + 1]) - Int(bp[k + 1]), db = Int(wp[k + 2]) - Int(bp[k + 2])
                        let alpha = max(0, min(255, 255 - (dr + dg + db) / 3))
                        guard alpha > 0 else { continue }
                        any = true
                        // Premultiplied, the colour on black is the colour times its alpha.
                        let a = UInt8(alpha)
                        op[k] = min(bp[k], a)
                        op[k + 1] = min(bp[k + 1], a)
                        op[k + 2] = min(bp[k + 2], a)
                        op[k + 3] = a
                    }
                }
            }
        }
        guard any else { return nil }
        return out.png()
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

    /// Reads the page and brings it into a design that is open (`slot`), beside what is there, an
    /// artboard a size, each named for the page. Says which they are and what came across.
    static func run(_ url: URL, sizes: [WebCapture.Size], hideBanners: Bool = true, into slot: WindowsCore.Slot, named name: String? = nil,
                    progress: ((String, Double) -> Void)? = nil) async throws -> (ids: [UUID], report: ImportReport) {
        var (reads, held) = try await read(url, sizes: sizes, hideBanners: hideBanners, progress: progress)
        progress?(String(localized: "Laying out the layers…"), 0.96)
        try Task.checkCancellation()
        guard slot.isOpen else { throw WebBrowser.Failure.gone }
        var named = WindowsCore.using(slot) { WindowsCore.design?.nodes ?? [] }
        for i in reads.indices {
            let size = sizes.isEmpty ? WebCapture.Size.desktop : sizes[i]
            let given = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            reads[i].name = !given.isEmpty && reads.count == 1 ? given : boardName(of: reads[i].page, size: size, among: named)
            named.append(Node(kind: .artboard, name: reads[i].name, frame: .zero))
        }
        return try WindowsCore.using(slot) { try WindowsCore.bringIn(reads, held: held, source: source(of: url)) }
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
        // Nor what Windows keeps out of file names.
        title = String(title.map { "\\*?\"<>|".contains($0) ? "-" : $0 }).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if title.count > 60 { title = String(title.prefix(60)).trimmingCharacters(in: .whitespaces) + "…" }
        return title.isEmpty ? source : title
    }
}
