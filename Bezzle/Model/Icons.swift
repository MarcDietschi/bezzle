import Foundation
import CoreGraphics

/// The icon sets that come with Bezzle, each drawn on a box of its own: Lucide's lines, drawn at
/// any weight; Phosphor's five weights; and Material Symbols, outlined or filled. Packed into
/// Icons.deflate by Scripts/icons/pack.py from each set's own files.
nonisolated enum IconSetID: String, CaseIterable, Codable, Sendable {
    case lucide, phosphor, material
}

nonisolated struct Icon: Hashable, Sendable {
    let set: IconSetID
    let name: String
    /// Words it is known by besides its name, for finding it.
    let tags: String
    /// Its outline in each of the set's styles, as SVG path data in the set's box; empty where
    /// the set has none in that style.
    let paths: [String]

    /// Its name as words, for showing: "arrow-up-right" is "arrow up right".
    var words: String { name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ") }
}

/// How an icon is drawn: which of its set's styles, and for a set of lines, how thick they are.
nonisolated struct IconStyle: Hashable, Codable, Sendable {
    /// Into the set's `styles`.
    var index: Int
    /// The width of a line set's lines, on its box of 24.
    var weight: CGFloat = 2
}

nonisolated struct IconSet: Sendable {
    let id: IconSetID
    let name: String
    /// Under what licence the set is shared, as SPDX names it.
    let licence: String
    /// The square each icon is drawn on.
    let box: CGRect
    /// For a set of lines, the width they are drawn with in the box; their paths are then the
    /// middles of the lines. Nil for sets of filled outlines.
    let stroke: CGFloat?
    /// The set's own names for its styles: "regular", "bold", "fill"…
    let styles: [String]
    let icons: [Icon]
    let byName: [String: Int]

    var drawnAsLines: Bool { stroke != nil }

    /// What a new icon of the set is drawn as: Phosphor's regular weight, the others' first style.
    var defaultStyle: IconStyle {
        IconStyle(index: styles.firstIndex(of: "regular") ?? 0, weight: stroke ?? 2)
    }

    func icon(_ name: String) -> Icon? { byName[name].map { icons[$0] } }
}

nonisolated enum Icons {
    /// Every set, read once, the first time any is asked for. Reading takes a moment, so the
    /// resources panel asks for them away from the main thread as it opens.
    static let sets: [IconSet] = load()

    static func set(_ id: IconSetID) -> IconSet {
        sets.first { $0.id == id } ?? IconSet(id: id, name: id.rawValue, licence: "", box: CGRect(x: 0, y: 0, width: 24, height: 24),
                                              stroke: nil, styles: [""], icons: [], byName: [:])
    }

    static func icon(_ name: String, in set: IconSetID) -> Icon? { self.set(set).icon(name) }

    /// Whether a layer is an icon from one of the sets, as its name says: what an icon dropped
    /// onto it takes the place of.
    static func isIcon(_ node: Node) -> Bool {
        node.kind == .path && sets.contains { $0.byName[node.name] != nil }
    }

    // MARK: Finding

    /// The icons whose name or words fit everything typed, best first: the name itself, then
    /// names starting with it, then those with it among their words.
    static func search(_ query: String, in id: IconSetID? = nil, limit: Int = .max) -> [Icon] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).map(String.init)
        let pool = sets.filter { id == nil || $0.id == id }
        guard !words.isEmpty else { return Array(pool.flatMap(\.icons).prefix(limit)) }
        let joined = words.joined(separator: "-")
        var found: [(rank: Int, order: Int, icon: Icon)] = []
        var order = 0
        for set in pool {
            let index = Self.index[set.id] ?? []
            for (i, icon) in set.icons.enumerated() {
                order += 1
                let (name, own, tags) = index[i]
                let rank: Int
                if name == joined { rank = 0 }
                else if name.hasPrefix(joined) { rank = 1 }
                else if words.allSatisfy({ w in own.contains { $0.hasPrefix(w) } }) { rank = 2 }
                else if words.allSatisfy({ w in own.contains { $0.hasPrefix(w) } || tags.contains { $0.hasPrefix(w) } }) { rank = 3 }
                else { continue }
                found.append((rank, order, icon))
            }
        }
        found.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.order < $1.order }
        return found.prefix(limit).map(\.icon)
    }

    /// Each icon's name with dashes, and its name's and tags' words, split once, for finding.
    private static let index: [IconSetID: [(name: String, own: [String], tags: [String])]] = Dictionary(uniqueKeysWithValues: sets.map { set in
        (set.id, set.icons.map { icon in
            let name = icon.name.replacingOccurrences(of: "_", with: "-")
            return (name, name.split(separator: "-").map(String.init), icon.tags.lowercased().split(separator: " ").map(String.init))
        })
    })

    // MARK: Drawing

    /// The icon's outline in a style, ready to fill, and the box it is drawn on: a line set's lines
    /// are grown into outlines of their weight, round at their ends and corners, and made one.
    static func outline(_ icon: Icon, style: IconStyle) -> (data: String, box: CGRect) {
        let set = self.set(icon.set)
        let index = icon.paths.indices.contains(style.index) && !icon.paths[style.index].isEmpty ? style.index : 0
        let data = icon.paths.indices.contains(index) ? icon.paths[index] : ""
        guard set.drawnAsLines else { return (data, set.box) }
        let key = OutlineKey(name: icon.name, set: icon.set, weight: style.weight)
        if let made = outlines.with({ $0[key] }) { return made }
        let width = max(0.25, min(style.weight, 6)) * set.box.width / 24
        let lines = PathData.cgPath(data)
        let grown = lines.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4).normalized(using: .winding)
        // Heavy lines can reach past the box; the box grows to hold them, so nothing is cut off.
        let box = set.box.union(grown.boundingBoxOfPath)
        let made = (PathData.string(grown), box)
        outlines.with {
            if $0.count > 3000 { $0.removeAll() }
            $0[key] = made
        }
        return made
    }

    /// A path layer of the icon, its set's box filling `frame`, in one colour.
    static func node(_ icon: Icon, style: IconStyle? = nil, frame: CGRect, color: RGBA) -> Node {
        let set = self.set(icon.set)
        let (data, box) = outline(icon, style: style ?? set.defaultStyle)
        let k = CGSize(width: frame.width / max(set.box.width, 1), height: frame.height / max(set.box.height, 1))
        let placed = CGRect(x: frame.minX + (box.minX - set.box.minX) * k.width, y: frame.minY + (box.minY - set.box.minY) * k.height,
                            width: box.width * k.width, height: box.height * k.height)
        var n = Node(kind: .path, name: icon.name, frame: placed)
        n.path = data
        n.pathBox = box
        n.fill = Fill(color: color)
        return n
    }

    /// The same layer with another icon's outline in it, as big as it was and in the same place,
    /// keeping its colours and everything else it has.
    static func swapped(_ node: Node, for icon: Icon, style: IconStyle? = nil) -> Node {
        let set = self.set(icon.set)
        // The box the old icon was drawn on, so the new one fills the same square.
        var square = node.frame
        if let old = sets.first(where: { $0.byName[node.name] != nil }), let box = node.pathBox, box.width > 0, box.height > 0 {
            let k = CGSize(width: node.frame.width / box.width, height: node.frame.height / box.height)
            square = CGRect(x: node.frame.minX + (old.box.minX - box.minX) * k.width, y: node.frame.minY + (old.box.minY - box.minY) * k.height,
                            width: old.box.width * k.width, height: old.box.height * k.height)
        }
        let made = self.node(icon, style: style ?? set.defaultStyle, frame: square, color: node.fill.color)
        var n = node
        n.name = made.name
        n.path = made.path
        n.pathBox = made.pathBox
        n.frame = made.frame
        n.evenOdd = nil
        return n
    }

    private struct OutlineKey: Hashable {
        let name: String, set: IconSetID, weight: CGFloat
    }
    private static let outlines = Shared([OutlineKey: (data: String, box: CGRect)]())

    // MARK: Reading

    private static func load() -> [IconSet] {
        guard let url = Bundle.main.url(forResource: "Icons", withExtension: "deflate"),
              let packed = try? Data(contentsOf: url),
              let raw = try? (packed as NSData).decompressed(using: .zlib) as Data,
              let top = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let list = top["sets"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { s -> IconSet? in
            guard let raw = s["id"] as? String, let id = IconSetID(rawValue: raw), let rows = s["icons"] as? [[String]],
                  let b = s["box"] as? [Double], b.count == 4 else { return nil }
            let icons = rows.compactMap { row -> Icon? in
                row.count >= 3 ? Icon(set: id, name: row[0], tags: row[1], paths: Array(row[2...])) : nil
            }
            var byName: [String: Int] = [:]
            for (i, icon) in icons.enumerated() where byName[icon.name] == nil { byName[icon.name] = i }
            return IconSet(id: id, name: s["name"] as? String ?? raw, licence: s["licence"] as? String ?? "",
                           box: CGRect(x: b[0], y: b[1], width: b[2], height: b[3]),
                           stroke: (s["stroke"] as? Double).map { CGFloat($0) },
                           styles: s["styles"] as? [String] ?? [""], icons: icons, byName: byName)
        }
    }
}
