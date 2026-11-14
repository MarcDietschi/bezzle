import Foundation
import CryptoKit

/// The icon library in the browser. On the Mac and on Windows it is a file beside the app
/// (Model/Kits/Icons.deflate, raw DEFLATE); a page has no such file, and the core has nothing
/// that unpacks DEFLATE. So the page fetches the file when it wants icons, unpacks it with the
/// browser's own `DecompressionStream('deflate-raw')` and hands it over (`bz_icons`); from
/// then on `Icons` answers here as it does on the Mac: its sets, finding an icon by its words,
/// each icon's outline at a weight.
///
/// The page that shows a shared design never asks for it: an icon in a design is an ordinary
/// path, drawn like any other, and only placing a new one needs the library.
///
/// Only here, in the browser's core: Bezzle for Windows reads the file itself (`NSData.inflate`).
enum WebIcons {
    /// Whether the library was handed over. Until then nothing here asks `Icons` for its sets:
    /// they are read once, the first time any is asked for, and would stay none.
    private static var given = false

    /// Takes the sets, unpacked, and answers which the core now has. The first time counts:
    /// the sets are read once (`Icons.sets`), as on the Mac.
    static func take(_ unpacked: Data) -> String {
        if !given { Icons.unpacked = unpacked }
        given = true
        let sets = Icons.sets
        // Read, they hold their own words: the page's copy is let go.
        Icons.unpacked = nil
        return "{\"sets\":[" + sets.map { s in
            "{\"id\":\(quoted(s.id.rawValue)),\"name\":\(quoted(s.name)),\"licence\":\(quoted(s.licence)),\"styles\":\(words(s.styles)),\"icons\":\(s.icons.count)}"
        }.joined(separator: ",") + "]}"
    }

    /// For comparing with the Mac (tools/icons.mjs): everything a set says of itself with a
    /// digest of all its icons, what is found for some words, some icons' outlines, and a sheet
    /// of icons as a design of one artboard, which is then the design shown.
    static func test(_ json: Data) -> (answer: String, sheet: BezzleDocument?) {
        let asked = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        guard given else { return ("{\"sets\":[]}", nil) }
        if asked["facts"] != nil {
            return ("{\"sets\":[" + Icons.sets.map { s in
                "{\"id\":\(quoted(s.id.rawValue)),\"name\":\(quoted(s.name)),\"licence\":\(quoted(s.licence)),\"box\":\(numbers([s.box.minX, s.box.minY, s.box.width, s.box.height]))"
                    + ",\"stroke\":\(s.stroke.map { "\(Double($0))" } ?? "null"),\"styles\":\(words(s.styles)),\"icons\":\(s.icons.count),\"digest\":\(quoted(digest(of: s)))}"
            }.joined(separator: ",") + "]}", nil)
        }
        if let searches = asked["search"] as? [[String: Any]] {
            let found = searches.map { one -> String in
                let set = (one["set"] as? String).flatMap(IconSetID.init(rawValue:))
                let limit = (one["limit"] as? NSNumber)?.intValue ?? 12
                return words(Icons.search(one["query"] as? String ?? "", in: set, limit: limit).map { "\($0.set.rawValue)/\($0.name)" })
            }
            return ("{\"found\":[" + found.joined(separator: ",") + "]}", nil)
        }
        if let wanted = asked["outlines"] as? [[String: Any]] {
            let made = wanted.map { one -> String in
                guard let (icon, style) = icon(one) else { return "null" }
                let (data, box) = Icons.outline(icon, style: style)
                return "{\"data\":\(quoted(data)),\"box\":\(numbers([box.minX, box.minY, box.width, box.height]))}"
            }
            return ("{\"outlines\":[" + made.joined(separator: ",") + "]}", nil)
        }
        if let sheet = asked["sheet"] as? [String: Any], let size = sheet["size"] as? [NSNumber], size.count == 2,
           let paper = (sheet["paper"] as? [NSNumber])?.map(\.doubleValue), paper.count == 3,
           let ink = (sheet["ink"] as? [NSNumber])?.map(\.doubleValue), ink.count == 3 {
            var board = Node(kind: .artboard, name: sheet["name"] as? String ?? "Icons", frame: CGRect(x: 0, y: 0, width: size[0].doubleValue, height: size[1].doubleValue))
            board.fill.color = RGBA(r: paper[0], g: paper[1], b: paper[2])
            var missing = 0
            for one in sheet["icons"] as? [[String: Any]] ?? [] {
                guard let (icon, style) = icon(one), let f = (one["frame"] as? [NSNumber])?.map(\.doubleValue), f.count == 4 else { missing += 1; continue }
                board.children.append(Icons.node(icon, style: style, frame: CGRect(x: f[0], y: f[1], width: f[2], height: f[3]), color: RGBA(r: ink[0], g: ink[1], b: ink[2])))
            }
            var doc = BezzleDocument()
            doc.nodes = [board]
            return ("{\"drawn\":\(board.children.count),\"missing\":\(missing)}", doc)
        }
        return ("{}", nil)
    }

    /// One icon and the style asked for it: {"set", "name", "style", "weight"}.
    private static func icon(_ one: [String: Any]) -> (Icon, IconStyle)? {
        guard let set = (one["set"] as? String).flatMap(IconSetID.init(rawValue:)), let name = one["name"] as? String,
              let icon = Icons.icon(name, in: set) else { return nil }
        var style = Icons.set(set).defaultStyle
        if let index = (one["style"] as? NSNumber)?.intValue { style.index = index }
        if let weight = (one["weight"] as? NSNumber)?.doubleValue { style.weight = CGFloat(weight) }
        return (icon, style)
    }

    /// Every icon of a set, its name, its words and its outlines, as one number: the Mac's test
    /// makes the same of its own (tools/IconTruthTests.swift).
    static func digest(of set: IconSet) -> String {
        var hasher = SHA256()
        for icon in set.icons {
            hasher.update(data: Data(([icon.name, icon.tags] + icon.paths).joined(separator: "\n").utf8))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
    }

    private static func numbers(_ values: [CGFloat]) -> String {
        "[" + values.map { $0.isFinite ? "\(Double($0))" : "0" }.joined(separator: ",") + "]"
    }

    private static func words(_ list: [String]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8), as: UTF8.self)
    }

    private static func quoted(_ s: String) -> String { String(words([s]).dropFirst().dropLast()) }
}
