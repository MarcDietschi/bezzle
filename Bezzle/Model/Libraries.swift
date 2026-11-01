import Foundation
import CryptoKit

// MARK: - Libraries

/// Every design is a library to every other, with nothing to set up or publish: its components
/// and its styles can be taken into any other design, from the resources panel, and come along
/// when its layers are pasted there. Taken in, a component or a style is the other design's own,
/// like any of its own, used and changed there as they are; it only remembers where it came from
/// and what it was like there then. When it has changed there since, the design it was taken into
/// is offered the change, which it takes or leaves (`BezzleDocument.update(from:)`). Nothing ever
/// changes another design by itself.
nonisolated struct LibraryLink: Codable, Hashable {
    /// What the design it came from was called when it was taken, or last brought up to date.
    var design: String
    /// What it was like there then (`Fingerprint`).
    var seen: String
}

/// What a component or a style is like, in a few letters: the same for the same, on any Mac.
nonisolated enum Fingerprint {
    static func of(_ master: Node) -> String {
        var m = master
        m.master?.library = nil
        return hash(m)
    }

    static func of(_ style: Style) -> String {
        struct Print: Encodable {
            var name: String
            var look: StyleLook
            var dark: StyleLook?
        }
        return hash(Print(name: style.name, look: style.look, dark: style.dark))
    }

    private static func hash<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "" }
        return SHA256.hash(data: data).prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}

/// What one design holds that others can take: its components and its styles, as last saved.
nonisolated struct LibraryContent: Sendable, Equatable {
    var url: URL
    var name: String
    var modified: Date
    var masters: [Node]
    var styles: [Style]
    /// What each component and style is like, by its id.
    var prints: [UUID: String]

    init(url: URL, name: String, modified: Date, masters: [Node], styles: [Style]) {
        // Every layer named after a style looks as it does, however the file was last written,
        // as when the design is opened.
        var doc = BezzleDocument()
        doc.components = masters.isEmpty ? nil : masters
        doc.styles = styles.isEmpty ? nil : styles
        doc.repairStyles()
        self.url = url
        self.name = name
        self.modified = modified
        self.masters = doc.masters
        self.styles = (doc.styles ?? []).sorted { ($0.kind.order, $0.rank) < ($1.kind.order, $1.rank) }
        var prints: [UUID: String] = [:]
        for m in self.masters { prints[m.id] = Fingerprint.of(m) }
        for s in self.styles { prints[s.id] = Fingerprint.of(s) }
        self.prints = prints
    }

    /// Reads only what a library needs from a design's file, not its canvas.
    static func read(_ url: URL, name: String, modified: Date) -> LibraryContent? {
        struct File: Decodable {
            var components: [Node]?
            var styles: [Style]?
        }
        let file = DesignFile.isPackage(url) ? url.appendingPathComponent(DesignFile.documentName) : url
        guard let data = try? Data(contentsOf: file), let read = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return LibraryContent(url: url, name: name, modified: modified, masters: read.components ?? [], styles: read.styles ?? [])
    }

    /// Its own components, made in it rather than taken from another design.
    var ownMasters: [Node] { masters.filter { $0.master?.library == nil } }
    /// Its own styles, likewise.
    var ownStyles: [Style] { styles.filter { $0.library == nil } }
    /// Whether it has anything of its own for other designs to take.
    var isLibrary: Bool { !ownMasters.isEmpty || !ownStyles.isEmpty }

    func master(_ id: UUID) -> Node? { masters.first { $0.id == id } }
    func style(_ id: UUID) -> Style? { styles.first { $0.id == id } }
    var mastersByID: [UUID: Node] { Dictionary(masters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

    /// What taking a component brings along: it, the components it holds copies of however deep,
    /// and the styles any of them are named after.
    func taking(_ id: UUID) -> LibraryTake {
        var doc = BezzleDocument()
        doc.components = masters
        let wanted = doc.uses(id).union([id])
        let brought = masters.filter { wanted.contains($0.id) }
        let named = brought.reduce(into: Set<UUID>()) { $0.formUnion($1.stylesUsed) }
        return LibraryTake(url: url, name: name, masters: brought, styles: styles.filter { named.contains($0.id) })
    }

    /// What taking a style brings along: the style.
    func taking(style id: UUID) -> LibraryTake {
        LibraryTake(url: url, name: name, masters: [], styles: styles.filter { $0.id == id })
    }
}

/// Components and styles on their way from one design into another, and where they come from.
nonisolated struct LibraryTake: Sendable, Equatable {
    var url: URL?
    var name: String?
    var masters: [Node] = []
    var styles: [Style] = []

    /// The pictures the components show, to come along into the other design's package.
    var pictures: Set<String> {
        var out = Set<String>()
        func visit(_ n: Node) {
            for f in [n.fill] + (n.moreFills ?? []) { if let image = f.image { out.formUnion(image.assets) } }
            for image in n.paintedPictures { out.formUnion(image.assets) }
            n.children.forEach(visit)
            n.mask?.forEach(visit)
        }
        masters.forEach(visit)
        return out
    }
}

private nonisolated extension StyleKind {
    var order: Int { StyleKind.allCases.firstIndex(of: self) ?? 0 }
}

/// What has changed in one library since a design took from it.
nonisolated struct LibraryNews: Hashable, Sendable {
    /// The design it is in now, and what that is called.
    var url: URL
    var name: String
    /// The design's components and styles to bring up to date, by their ids.
    var masters: [UUID] = []
    var styles: [UUID] = []
    /// Their fingerprints there now, by id, to tell this news from newer.
    var prints: [UUID: String] = [:]

    var count: Int { masters.count + styles.count }
}

nonisolated enum Libraries {
    /// The design a component came from, among these: one that has it as its own, the one under
    /// the name it came from if there is such, else the one changed last. Nil when none has it.
    static func source(master id: UUID, link: LibraryLink, in libraries: [LibraryContent]) -> LibraryContent? {
        pick(libraries.filter { $0.ownMasters.contains { $0.id == id } }, link)
    }

    /// The design a style came from, likewise.
    static func source(style id: UUID, link: LibraryLink, in libraries: [LibraryContent]) -> LibraryContent? {
        pick(libraries.filter { $0.ownStyles.contains { $0.id == id } }, link)
    }

    private static func pick(_ found: [LibraryContent], _ link: LibraryLink) -> LibraryContent? {
        found.first { $0.name == link.design } ?? found.max { $0.modified < $1.modified }
    }
}

nonisolated extension BezzleDocument {
    /// Takes in components and styles from another design (`from`, its name), as layers brought
    /// from it need them. One this design has already stays as it is here; a style of the same kind
    /// and name stands in for one it does not have; anything else comes along, remembering where
    /// it came from, unless it remembers already, as one taken from a third design does. Returns
    /// how the names of styles are to change in what is brought.
    @discardableResult
    mutating func bring(_ take: LibraryTake) -> [UUID: UUID] {
        let from = take.name
        let linked = take.styles.map { s -> Style in
            var t = s
            if t.library == nil, let from { t.library = LibraryLink(design: from, seen: Fingerprint.of(s)) }
            return t
        }
        let map = takeIn(linked)
        let have = Set(masters.map(\.id))
        let new = take.masters.filter { !have.contains($0.id) }.map { m -> Node in
            var n = m.renamingStyles(map)
            if n.master?.library == nil, let from { n.master?.library = LibraryLink(design: from, seen: Fingerprint.of(m)) }
            return n
        }
        if !new.isEmpty { masters += Self.resolvingStyles(new, with: stylesByID) }
        return map
    }

    /// Components looking as the styles they are named after look in this design.
    private static func resolvingStyles(_ list: [Node], with styles: [UUID: Style]) -> [Node] {
        var doc = BezzleDocument()
        doc.components = list
        doc.styles = Array(styles.values)
        doc.repairStyles()
        return doc.masters
    }

    /// The components and styles this design took from other designs that have changed there
    /// since, by the design each is in now. What was changed here only is no news.
    func libraryNews(in libraries: [LibraryContent]) -> [LibraryNews] {
        var out: [URL: LibraryNews] = [:]
        var order: [URL] = []
        func note(_ lib: LibraryContent, master: UUID? = nil, style: UUID? = nil) {
            if out[lib.url] == nil {
                out[lib.url] = LibraryNews(url: lib.url, name: lib.name)
                order.append(lib.url)
            }
            if let master { out[lib.url]?.masters.append(master); out[lib.url]?.prints[master] = lib.prints[master] }
            if let style { out[lib.url]?.styles.append(style); out[lib.url]?.prints[style] = lib.prints[style] }
        }
        for s in styles ?? [] {
            guard let link = s.library, let lib = Libraries.source(style: s.id, link: link, in: libraries),
                  let now = lib.prints[s.id], now != link.seen else { continue }
            note(lib, style: s.id)
        }
        for m in masters {
            guard let link = m.master?.library, let lib = Libraries.source(master: m.id, link: link, in: libraries),
                  let now = lib.prints[m.id], now != link.seen else { continue }
            note(lib, master: m.id)
        }
        return order.compactMap { out[$0] }
    }

    /// Brings components and styles taken from `library` up to date with it: each made again as it
    /// is there, keeping its id, so every copy of a component follows (`syncComponents`) and every
    /// layer named after a style (`syncStyles`). What they hold or are named after that this design
    /// does not have comes along. Copies keep what is their own, as they always do.
    mutating func update(from library: LibraryContent, masters ids: [UUID], styles sids: [UUID]) {
        // Styles first, so the components brought up to date look as they do.
        for id in sids {
            guard let s = library.style(id), style(id) != nil else { continue }
            changeStyle(id) { t in
                t.name = s.name
                t.look = s.look
                t.dark = s.dark
                t.library = LibraryLink(design: library.name, seen: library.prints[id] ?? Fingerprint.of(s))
            }
        }
        for id in ids {
            guard let theirs = library.master(id), master(id) != nil else { continue }
            var take = library.taking(id)
            take.masters.removeAll { $0.id == id }
            let map = bring(take)
            var m = theirs.renamingStyles(map)
            m.master?.library = LibraryLink(design: library.name, seen: library.prints[id] ?? Fingerprint.of(theirs))
            m = Self.resolvingStyles([m], with: stylesByID).first ?? m
            var list = masters
            if let i = list.firstIndex(where: { $0.id == id }) { list[i] = m }
            masters = list
        }
    }
}
