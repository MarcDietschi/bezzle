import Foundation
import CBezzleHost

// MARK: - Libraries

/// The other designs as libraries for the open one, as the Mac's LibraryShelf keeps them: what each
/// holds that others can take, read from its file away from the main thread, once each time it
/// changes; news of what changed there since this design took from it; and taking. See `LibraryLink`.
extension WindowsCore {
    nonisolated(unsafe) private static var shelf: [URL: LibraryContent] = [:]
    nonisolated(unsafe) private static var shelfOrder: [URL] = []
    nonisolated(unsafe) private static var reading = false
    /// News set aside, by design, what it was about and how it was then, so newer news still shows.
    nonisolated(unsafe) private static var setAside: [String: Set<String>] = [:]
    /// Pictures of other designs given to Skia, by name.
    nonisolated(unsafe) private static var given: Set<String> = []

    nonisolated public struct LibraryLook: Sendable {
        public let url: URL
        public let name: String
        public let components: Int
        public let styles: Int
        /// What was taken from it changed there since.
        public let news: Bool
    }

    static func same(_ a: URL, _ b: URL?) -> Bool {
        guard let b else { return false }
        return a.standardizedFileURL.path.lowercased() == b.standardizedFileURL.path.lowercased()
    }

    /// Reads the designs that changed since they were last read, all but the open one, and then
    /// says so (`done`), on the main thread.
    public static func readLibraries(_ urls: [URL], done: @escaping @MainActor () -> Void) {
        guard !reading else { return }
        let open = designURL
        func modified(_ url: URL) -> Date {
            let file = url.appendingPathComponent("document.json")
            let at = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
                ?? (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            return at ?? .distantPast
        }
        let wanted = urls.filter { !same($0, open) }.map { ($0, modified($0)) }
        let stale = wanted.filter { shelf[$0.0]?.modified != $0.1 }
        shelfOrder = wanted.map(\.0)
        guard !stale.isEmpty else { done(); return }
        reading = true
        let jobs = stale.map { ($0.0, $0.0.deletingPathExtension().lastPathComponent, $0.1) }
        Task.detached(priority: .utility) {
            var read: [(URL, LibraryContent)] = []
            for (url, name, at) in jobs {
                if let content = LibraryContent.read(url, name: name, modified: at) { read.append((url, content)) }
            }
            let made = read
            await MainActor.run {
                for (url, content) in made { shelf[url] = content }
                reading = false
                done()
            }
        }
    }

    /// Every design read, all but the open one, in the home screen's order (the AI server's).
    static var shelfContents: [LibraryContent] { shelfOrder.compactMap { shelf[$0] } }

    /// Reads them as `readLibraries` does, once a reading going on is done.
    static func refreshLibraries(_ urls: [URL]) async {
        while reading { try? await Task.sleep(for: .milliseconds(50)) }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in readLibraries(urls) { done.resume() } }
    }

    /// The designs that have components or styles of their own, in the home screen's order.
    public static func libraries() -> [LibraryLook] {
        let news = Set(currentNews().map(\.url))
        return shelfOrder.compactMap { shelf[$0] }.filter(\.isLibrary).map {
            LibraryLook(url: $0.url, name: $0.name, components: $0.ownMasters.count, styles: $0.ownStyles.count, news: news.contains($0.url))
        }
    }

    static func library(_ url: URL) -> LibraryContent? { shelf.first { same($0.key, url) }?.value }

    public static func libraryComponents(_ url: URL, query: String) -> [(id: UUID, name: String, taken: Bool)] {
        guard let lib = library(url) else { return [] }
        return lib.ownMasters.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .map { ($0.id, $0.name, design?.master($0.id) != nil) }
    }

    /// A style of another design, as its chip shows it.
    nonisolated public struct LibraryStyleLook: Sendable {
        public let id: UUID
        public let name: String
        public let taken: Bool
        /// "colour", "text", "shadow" or "corners".
        public let kind: String
        public let colour: UInt32
        public let alpha: Double
        /// Under a gradient, its colours.
        public let gradient: [UInt32]
        public let family: String
        public let radius: Double
        public let shadow: (x: Double, y: Double, blur: Double, colour: UInt32, alpha: Double)?
    }

    private static func chip(_ s: Style, taken: Bool) -> LibraryStyleLook {
        func hexOf(_ c: RGBA) -> UInt32 {
            func b(_ v: Double) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
            return b(Double(c.r)) << 16 | b(Double(c.g)) << 8 | b(Double(c.b))
        }
        switch s.look {
        case .colour(let p):
            return LibraryStyleLook(id: s.id, name: s.name, taken: taken, kind: "colour", colour: hexOf(p.color), alpha: Double(p.color.a),
                             gradient: p.gradient?.stops.map { hexOf($0.color) } ?? [], family: "", radius: 0, shadow: nil)
        case .text(let t):
            return LibraryStyleLook(id: s.id, name: s.name, taken: taken, kind: "text", colour: 0, alpha: 1, gradient: [], family: t.family, radius: 0, shadow: nil)
        case .shadow(let sh):
            return LibraryStyleLook(id: s.id, name: s.name, taken: taken, kind: "shadow", colour: 0, alpha: 1, gradient: [], family: "", radius: 0,
                             shadow: (Double(sh.x), Double(sh.y), Double(sh.blur), hexOf(sh.color), Double(sh.color.a)))
        case .corners(let c):
            return LibraryStyleLook(id: s.id, name: s.name, taken: taken, kind: "corners", colour: 0, alpha: 1, gradient: [], family: "", radius: Double(c.radius), shadow: nil)
        }
    }

    public static func libraryStyles(_ url: URL, query: String) -> [LibraryStyleLook] {
        guard let lib = library(url) else { return [] }
        return lib.ownStyles.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .map { chip($0, taken: design?.style($0.id) != nil) }
    }

    /// Up to eight of a library's colours, for its cover.
    public static func libraryColours(_ url: URL) -> [LibraryStyleLook] {
        guard let lib = library(url) else { return [] }
        return lib.ownStyles.filter { $0.look.paint != nil }.prefix(8).map { chip($0, taken: false) }
    }

    /// Gives Skia a library's pictures that the layers taken from it show, by their names.
    private static func give(pictures names: Set<String>, from url: URL) {
        let images = url.appendingPathComponent("images", isDirectory: true)
        for name in names where !given.contains(name) {
            guard let data = try? Data(contentsOf: images.appendingPathComponent(name)) else { continue }
            _ = data.withUnsafeBytes { bz_asset_add(name, $0.baseAddress, Int32($0.count)) }
            given.insert(name)
        }
    }

    /// A component of another design, as a new copy of it would look, fitted into `size`.
    public static func libraryPicture(_ url: URL, master id: UUID, size: CGSize, scale: Double,
                                      into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> Bool {
        guard let lib = library(url), let master = lib.master(id) else { return false }
        give(pictures: lib.taking(id).pictures, from: url)
        var holder = BezzleDocument()
        holder.nodes = [Components.newCopy(of: master, at: .zero, masters: lib.mastersByID)]
        holder.fitGroups()
        guard var shown = holder.nodes.first else { return false }
        shown.rotation = 0
        let box = Geometry.bounds(of: shown)
        guard box.width > 0, box.height > 0 else { return false }
        let k = min(size.width / box.width, size.height / box.height, 2)
        let w = size.width / k, h = size.height / k
        shown.frame.origin = CGPoint(x: (w - box.width) / 2 + (shown.frame.minX - box.minX), y: (h - box.height) / 2 + (shown.frame.minY - box.minY))
        return drawGlyph([shown], size: CGSize(width: w, height: h), scale: scale * Double(k), into: fill)
    }

    /// The first few components of a library, for its cover.
    public static func libraryCoverComponents(_ url: URL) -> [UUID] {
        library(url)?.ownMasters.prefix(3).map(\.id) ?? []
    }

    /// Copies the pictures components from another design show into this design's package, where
    /// they are not yet, as the Mac's bringPictures does.
    static func bringPictures(_ take: LibraryTake) {
        guard let from = take.url, let url = designURL, !same(from, url) else { return }
        let names = take.pictures
        guard !names.isEmpty else { return }
        let source = from.appendingPathComponent("images", isDirectory: true)
        let fm = FileManager.default
        let wanted = names.filter { fm.fileExists(atPath: source.appendingPathComponent($0).path) }
        guard !wanted.isEmpty, (try? makePackage()) != nil else { return }
        let images = url.appendingPathComponent("images", isDirectory: true)
        try? fm.createDirectory(at: images, withIntermediateDirectories: true)
        for name in wanted where !fm.fileExists(atPath: images.appendingPathComponent(name).path) {
            try? fm.copyItem(at: source.appendingPathComponent(name), to: images.appendingPathComponent(name))
        }
        give(pictures: Set(wanted), from: from)
    }

    // MARK: Taking

    /// Gives the selection a style of another design, which comes into this one with it; with
    /// nothing selected, only brings it in. It goes where the open card holds one of its kind
    /// (`open`, as `stylePlace` reads it), else where a style of its kind goes.
    public static func useStyle(_ id: UUID, of url: URL, on targets: [UUID], at open: String? = nil) {
        guard let lib = library(url) else { return }
        let take = lib.taking(style: id)
        guard !take.styles.isEmpty else { return }
        edit { $0.use(id, taking: take, on: targets, at: open.flatMap(stylePlace)) }
    }

    /// A style shown on the selection without being given, while the pointer is on it.
    public static func previewStyle(_ id: UUID?, of url: URL, on targets: [UUID], at open: String? = nil) {
        endPreview()
        guard let id, !targets.isEmpty, let style = library(url)?.style(id), let doc = design else { return }
        preview { d in
            for t in targets {
                d.update(t) { n in
                    var shown = style
                    shown.look = style.look(dark: doc.isDark(n.id))
                    n.give(shown, at: open.flatMap(stylePlace), dark: false, naming: false)
                }
            }
        }
    }

    // MARK: News

    nonisolated public struct NewsLook: Sendable {
        public let url: URL
        public let name: String
        /// "New in “Design System”: Button, Primary +2"
        public let words: String
    }

    private static func key(_ id: UUID, _ print: String?) -> String { "\(id.uuidString)|\(print ?? "")" }

    /// Read from the design as it is, not as a change pointed at shows it: pointing at Update
    /// shows the design brought up to date, which has no news, and the note offering it, with the
    /// button under the pointer, would go and come again, so that the click never landed.
    private static func currentNews() -> [LibraryNews] {
        guard let doc = previewBase ?? design, let url = designURL else { return [] }
        let aside = setAside[url.standardizedFileURL.path] ?? []
        let others = shelfOrder.compactMap { shelf[$0] }
        return doc.libraryNews(in: others).compactMap { news in
            var n = news
            n.masters.removeAll { aside.contains(key($0, news.prints[$0])) }
            n.styles.removeAll { aside.contains(key($0, news.prints[$0])) }
            return n.count == 0 ? nil : n
        }
    }

    /// What changed in other designs since this one took from them, but what was set aside.
    public static func news() -> [NewsLook] {
        guard let doc = previewBase ?? design else { return [] }
        return currentNews().map { news in
            let names = news.masters.compactMap { doc.master($0)?.name } + news.styles.compactMap { doc.style($0)?.name }
            var list = names.prefix(2).joined(separator: ", ")
            if names.count > 2 { list += " +\(names.count - 2)" }
            return NewsLook(url: news.url, name: news.name, words: say("New in “%@”: %@", news.name, list))
        }
    }

    /// Brings components and styles taken from another design up to date with it.
    public static func update(from url: URL) {
        guard let news = currentNews().first(where: { same($0.url, url) }), let lib = library(url) else { return }
        bringPictures(lib.taking(news.masters))
        edit { $0.update(from: lib, masters: news.masters, styles: news.styles) }
    }

    /// The design shown brought up to date, while the pointer is on the offer, or as it is (nil).
    /// Answers the layers that would change, to outline.
    @discardableResult
    public static func previewUpdate(from url: URL?) -> [UUID] {
        endPreview()
        guard let url, let news = currentNews().first(where: { same($0.url, url) }), let lib = library(url), let doc = design else { return [] }
        give(pictures: lib.taking(news.masters).pictures, from: url)
        preview { $0.update(from: lib, masters: news.masters, styles: news.styles) }
        let users = doc.styleUsers()
        return news.masters.flatMap { doc.copies(of: $0).map(\.id) } + news.styles.flatMap { users[$0] ?? [] }
    }

    /// Leaves news as it is: it shows again only once there is newer.
    public static func setNewsAside(_ url: URL) {
        guard let design = designURL, let news = currentNews().first(where: { same($0.url, url) }) else { return }
        let keys = (news.masters + news.styles).map { key($0, news.prints[$0]) }
        setAside[design.standardizedFileURL.path, default: []].formUnion(keys)
    }
}
