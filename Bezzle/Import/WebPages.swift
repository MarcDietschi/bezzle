import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// What Bezzle's browser and the import from a website work out without asking a browser, the same
// on the Mac and on Windows (linked into Windows/Sources/BezzleCore/Import): which pages of a site
// are offered to bring in, what the artboards pages come in as are called and where they go in a
// design, and which cookies go along with a picture fetched from behind a sign-in.

/// A page of a site that can be brought in: the one open in Bezzle's browser, one visited before
/// in it, or one the page links to.
struct WebSitePage: Identifiable, Hashable {
    enum Kind { case open, visited, linked }
    var url: URL
    var name: String
    var kind: Kind
    var id: String { Self.plain(url).absoluteString }

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

    /// The pages to offer, each once: the one open (`here`, called `title`), then those visited in
    /// the browser on the same site, newest first, that are safe to load again, then those the page
    /// links to, as the hands list them (WebPageHands.js `pages`, as JSON).
    static func offered(open here: URL, title: String, visited: [(url: URL, title: String?)], links: String?) -> [WebSitePage] {
        var found = [WebSitePage(url: plain(here), name: title.isEmpty ? (here.host ?? here.absoluteString) : title, kind: .open)]
        var seen: Set<String> = [found[0].id]
        for item in visited {
            let page = WebSitePage(url: plain(item.url), name: item.title?.isEmpty == false ? item.title! : item.url.path, kind: .visited)
            guard item.url.host == here.host, item.url.scheme == here.scheme, !doesSomething(item.url), seen.insert(page.id).inserted else { continue }
            found.append(page)
        }
        if let links, let list = (try? JSONSerialization.jsonObject(with: Data(links.utf8))) as? [[String: Any]] {
            for link in list {
                guard let address = link["url"] as? String, let to = URL(string: address) else { continue }
                let page = WebSitePage(url: plain(to), name: link["name"] as? String ?? to.path, kind: .linked)
                guard seen.insert(page.id).inserted else { continue }
                found.append(page)
            }
        }
        return found
    }
}

extension WebImport {
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

    /// Where pages brought into a design go: the row of them as it was made, moved so that it
    /// begins 400 points to the right of everything already on the canvas, its top level with
    /// the highest artboard there; on an empty canvas, where it was made.
    static func placed(_ boards: [Node], beside nodes: [Node]) -> [Node] {
        guard let first = boards.first else { return [] }
        let start = boards.map(\.frame).reduce(first.frame) { $0.union($1) }
        let right = nodes.map(\.frame.maxX).max()
        let top = nodes.filter(\.isArtboard).map(\.frame.minY).min() ?? nodes.map(\.frame.minY).min()
        let dx = right.map { ($0 + 400 - start.minX).rounded() } ?? 0
        let dy = top.map { ($0 - start.minY).rounded() } ?? 0
        return boards.map { board in
            var b = board
            b.frame = b.frame.offsetBy(dx: dx, dy: dy)
            return b
        }
    }
}

extension WebCapture {
    /// The cookies a browser sends along to `url`: those of its host or of a domain it is in, on
    /// a path it is on, not yet gone, and only over HTTPS when they say so.
    nonisolated static func cookies(for url: URL, among all: [HTTPCookie], now: Date = Date()) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        let secure = url.scheme?.lowercased() == "https"
        return all.filter { c in
            var domain = c.domain.lowercased()
            let wide = domain.hasPrefix(".")
            if wide { domain.removeFirst() }
            // A cookie a site set for its domain says so with a dot, and holds for the hosts in it.
            guard host == domain || (wide && host.hasSuffix("." + domain)) else { return false }
            let cp = c.path.isEmpty ? "/" : c.path
            guard path == cp || path.hasPrefix(cp.hasSuffix("/") ? cp : cp + "/") else { return false }
            if c.isSecure && !secure { return false }
            if let expires = c.expiresDate, expires < now { return false }
            return true
        }
    }
}
