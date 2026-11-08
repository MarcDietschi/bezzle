import Foundation
import CBezzleHost

// Windows' own fonts, as the Mac offers every font the Mac has: read by name as Bezzle starts
// (each file's name table only, so starting stays quick), listed beside the open fonts, and given
// to Skia the first time a text is set in one (`Fonts.need`). Where Windows has the very face a
// design asks for (Arial, Georgia, Segoe UI…), it is used rather than the open look-alike.

extension WindowsCore {
    /// A face Windows has: its file, and which font of a collection (.ttc) it is.
    nonisolated struct InstalledFace: Sendable {
        let url: URL
        let index: Int
    }

    nonisolated(unsafe) static var installed: [String: [String: InstalledFace]] = [:]
    nonisolated(unsafe) private static var given: Set<String> = []
    nonisolated private static let giving = NSLock()

    /// The folders Windows keeps fonts in: for everyone, and for the person signed in.
    nonisolated private static var fontFolders: [URL] {
        var folders = [URL(fileURLWithPath: (ProcessInfo.processInfo.environment["WINDIR"] ?? "C:\\Windows") + "\\Fonts", isDirectory: true)]
        if let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"] {
            folders.append(URL(fileURLWithPath: local + "\\Microsoft\\Windows\\Fonts", isDirectory: true))
        }
        return folders
    }

    /// Reads which families and faces Windows has, and lists them with the open fonts: a family
    /// Windows has itself is no longer stood in for.
    static func readInstalledFonts() {
        var found: [String: [String: InstalledFace]] = [:]
        for folder in fontFolders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in files where ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased()) {
                for (index, names) in FontNames.read(url).enumerated() {
                    guard let names, !names.family.hasPrefix("."), found[names.family]?[names.face] == nil else { continue }
                    found[names.family, default: [:]][names.face] = InstalledFace(url: url, index: index)
                }
            }
        }
        // The Mac's families Windows lacks, drawn in one of its own very like them, under the
        // Mac's names, as the open fonts stand in for others.
        for (mac, theirs, faces) in lookAlikes where found[mac] == nil {
            guard let own = found[theirs] else { continue }
            var alike: [String: InstalledFace] = [:]
            for (face, ownFace) in faces { alike[face] = own[ownFace] }
            guard !alike.isEmpty else { continue }
            found[mac] = alike
            standingIn[mac] = theirs
        }
        installed = found
        var families = NSFontManager.shared.families
        for (family, faces) in found {
            families[family] = Fonts.ordered(Array(faces.keys))
        }
        NSFontManager.shared.families = families
        MacFonts.standIns.subtract(found.keys)
        Fonts.need = { family, face in WindowsCore.give(family, face) }
    }

    /// Whether a family is one of Windows' own, which WinUI can show by its name (`shownAs`).
    public static func isInstalled(_ family: String) -> Bool { installed[family] != nil }

    /// The name WinUI knows a family by: its own, or for one of the Mac's that a font of Windows
    /// stands in for, that font's.
    public static func shownAs(_ family: String) -> String { standingIn[family] ?? family }

    /// The Mac's families that Windows has a cousin of, face by face, each about as wide as the
    /// Mac's (measured with Core Text: within a few hundredths, so words break where they do on
    /// the Mac): Charter in Cambria, Bradley Hand in Ink Free. The welcome tour is set in them.
    nonisolated private static let lookAlikes: [(mac: String, windows: String, faces: [String: String])] = [
        ("Charter", "Cambria", ["Roman": "Regular", "Italic": "Italic", "Bold": "Bold", "Bold Italic": "Bold Italic",
                                "Black": "Bold", "Black Italic": "Bold Italic"]),
        ("Bradley Hand", "Ink Free", ["Bold": "Regular"]),
    ]
    nonisolated(unsafe) private static var standingIn: [String: String] = [:]

    /// Gives Skia a face Windows has, the first time it is asked for; any thread.
    nonisolated static func give(_ family: String, _ face: String) {
        guard let entry = installed[family]?[face] else { return }
        let key = family + "|" + face
        giving.lock()
        defer { giving.unlock() }
        guard !given.contains(key), let data = try? Data(contentsOf: entry.url) else { return }
        given.insert(key)
        let added = data.withUnsafeBytes { bz_font_add_at(family, face, $0.baseAddress, Int32($0.count), Int32(entry.index)) }
        if added != 0 { Fonts.files["\(family)/\(face)"] = entry.url }
    }
}

extension Fonts {
    /// Faces in the order a menu lists them: by weight, upright before leaning.
    nonisolated static func ordered(_ faces: [String]) -> [String] {
        faces.sorted { a, b in
            let (wa, ia) = traits(named: a), (wb, ib) = traits(named: b)
            return (wa, ia ? 1 : 0, a) < (wb, ib ? 1 : 0, b)
        }
    }
}

/// A font file's names as its name table gives them: the family and face it belongs to, for
/// each font in it (a .ttc holds several). Only the table directory and the name table are read.
nonisolated enum FontNames {
    struct Names: Sendable { let family: String; let face: String }

    static func read(_ url: URL) -> [Names?] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        func bytes(_ offset: Int, _ count: Int) -> [UInt8]? {
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil, let data = try? handle.read(upToCount: count), data.count == count else { return nil }
            return [UInt8](data)
        }
        guard let head = bytes(0, 12) else { return [] }
        if head[0..<4] == [0x74, 0x74, 0x63, 0x66] {
            // A collection: how many fonts, then where each one's table directory is.
            let n = min(Int(u32(head, 8)), 64)
            guard let offsets = bytes(12, n * 4) else { return [] }
            return (0..<n).map { names(at: Int(u32(offsets, $0 * 4)), bytes) }
        }
        return [names(at: 0, bytes)]
    }

    private static func names(at start: Int, _ bytes: (Int, Int) -> [UInt8]?) -> Names? {
        guard let dir = bytes(start, 12) else { return nil }
        let tables = Int(u16(dir, 4))
        guard tables > 0, tables < 200, let records = bytes(start + 12, tables * 16) else { return nil }
        for t in 0..<tables where records[t * 16..<t * 16 + 4] == [0x6E, 0x61, 0x6D, 0x65] {
            let offset = Int(u32(records, t * 16 + 8)), length = Int(u32(records, t * 16 + 12))
            guard length > 6, length < 1 << 22, let table = bytes(offset, length) else { return nil }
            return parse(table)
        }
        return nil
    }

    /// The typographic family and face (ids 16 and 17) where the font has them, else its family
    /// and style (1 and 2); in American English where given, Windows' own Unicode names.
    private static func parse(_ t: [UInt8]) -> Names? {
        let count = Int(u16(t, 2)), strings = Int(u16(t, 4))
        var found: [Int: (rank: Int, value: String)] = [:]
        for k in 0..<count {
            let r = 6 + k * 12
            guard r + 12 <= t.count else { break }
            let platform = u16(t, r), encoding = u16(t, r + 2), language = u16(t, r + 4), id = Int(u16(t, r + 6))
            let length = Int(u16(t, r + 8)), offset = strings + Int(u16(t, r + 10))
            guard [1, 2, 16, 17].contains(id), offset + length <= t.count else { continue }
            let rank: Int
            if platform == 3, encoding == 1 || encoding == 10 { rank = language == 0x409 ? 0 : 1 } else if platform == 0 { rank = 2 } else { continue }
            guard found[id].map({ $0.rank > rank }) ?? true else { continue }
            var units: [UInt16] = []
            for i in stride(from: offset, to: offset + length - 1, by: 2) { units.append(UInt16(t[i]) << 8 | UInt16(t[i + 1])) }
            found[id] = (rank, String(decoding: units, as: UTF16.self))
        }
        guard let family = found[16]?.value ?? found[1]?.value, !family.isEmpty else { return nil }
        let face = found[17]?.value ?? found[2]?.value ?? "Regular"
        return Names(family: family, face: face)
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { i + 1 < b.count ? UInt16(b[i]) << 8 | UInt16(b[i + 1]) : 0 }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        i + 3 < b.count ? UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) : 0
    }
}
