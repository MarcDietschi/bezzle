import Foundation

// What a font says of itself, read from its file's tables, where the Mac asks Core Text: the
// OpenType features it can turn on (Fonts.features) and, for a variable font, the axes it can
// be set along (Fonts.axes), each by the name the font gives it.

extension Fonts {
    /// An OpenType feature a font has, by its tag, as the font names it.
    nonisolated struct Feature: Hashable, Sendable {
        let tag: String
        let name: String
    }

    /// One axis a variable font can be set along.
    nonisolated struct Axis: Hashable, Sendable {
        let tag: String
        let name: String
        let range: ClosedRange<Double>
        let standard: Double
    }

    /// The file of each face, by "family/face"; the system font's under "System/".
    nonisolated(unsafe) static var files: [String: URL] = [:]
    nonisolated(unsafe) private static var read: [URL: FontFile] = [:]

    private static func file(_ style: TextStyle) -> FontFile? {
        let key = style.family == TextStyle.system ? "System/" : "\(style.family)/\(style.face)"
        guard let url = files[key] ?? files.first(where: { $0.key.hasPrefix(style.family + "/") })?.value else { return nil }
        return file(at: url)
    }

    static func file(at url: URL) -> FontFile {
        if let known = read[url] { return known }
        let file = (try? Data(contentsOf: url)).flatMap(FontFile.init) ?? FontFile(features: [], axes: [])
        read[url] = file
        return file
    }

    /// The OpenType features the face of `style` can turn on, in the order it lists them.
    static func features(of style: TextStyle) -> [Feature] { file(style)?.features ?? [] }

    /// The axes of a variable font that are meant to be set by hand; none for any other font.
    static func axes(of style: TextStyle) -> [Axis] { file(style)?.axes ?? [] }
}

/// A font file's features and axes, from its GSUB, fvar and name tables.
nonisolated struct FontFile {
    let features: [Fonts.Feature]
    let axes: [Fonts.Axis]
    /// The family the file names itself.
    var family: String?

    init(features: [Fonts.Feature], axes: [Fonts.Axis], family: String? = nil) {
        self.features = features
        self.axes = axes
        self.family = family
    }

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { at + 1 < bytes.count ? Int(bytes[at]) << 8 | Int(bytes[at + 1]) : 0 }
        func u32(_ at: Int) -> Int { u16(at) << 16 | u16(at + 2) }
        func fixed(_ at: Int) -> Double { Double(Int32(truncatingIfNeeded: u32(at))) / 65536 }
        func tag(_ at: Int) -> String { String(bytes: bytes[at..<min(at + 4, bytes.count)], encoding: .ascii) ?? "" }
        guard bytes.count > 12 else { return nil }
        // A collection's first font.
        let start = tag(0) == "ttcf" ? u32(12) : 0
        var tables: [String: Int] = [:]
        for k in 0..<u16(start + 4) {
            let record = start + 12 + k * 16
            tables[tag(record)] = u32(record + 8)
        }

        // The names a font gives its features and axes: Windows' English ones first, else the Mac's.
        func name(_ id: Int) -> String? {
            guard let table = tables["name"] else { return nil }
            let count = u16(table + 2), strings = table + u16(table + 4)
            var mac: String?
            for k in 0..<count {
                let r = table + 6 + k * 12
                guard u16(r + 6) == id else { continue }
                let platform = u16(r), language = u16(r + 4), length = u16(r + 8), offset = strings + u16(r + 10)
                guard offset + length <= bytes.count else { continue }
                if platform == 3, language == 0x409 {
                    let units = stride(from: offset, to: offset + length - 1, by: 2).map { UInt16(u16($0)) }
                    return String(decoding: units, as: UTF16.self)
                }
                if platform == 1, mac == nil { mac = String(bytes: bytes[offset..<offset + length], encoding: .macOSRoman) }
            }
            return mac
        }

        var features: [Fonts.Feature] = []
        var seen = Set<String>()
        if let gsub = tables["GSUB"] {
            let list = gsub + u16(gsub + 6)
            for k in 0..<u16(list) {
                let record = list + 2 + k * 6
                let t = tag(record)
                guard seen.insert(t).inserted else { continue }
                // A stylistic set's or character variant's own name, kept with its parameters.
                let feature = list + u16(record + 4), params = u16(feature)
                var named: String?
                if params != 0 {
                    let p = feature + params
                    if TextFeatures.isStylisticSet(t) { named = name(u16(p + 2)) }
                    if TextFeatures.isCharacterVariant(t) { named = name(u16(p + 4)) }
                }
                let number = Int(t.dropFirst(2)) ?? 0
                let fallback = TextFeatures.isStylisticSet(t) ? "Stylistic Set \(number)"
                    : TextFeatures.isCharacterVariant(t) ? "Character Variant \(number)" : t
                features.append(Fonts.Feature(tag: t, name: named?.isEmpty == false ? named! : fallback))
            }
        }

        var axes: [Fonts.Axis] = []
        if let fvar = tables["fvar"] {
            let first = fvar + u16(fvar + 4), count = u16(fvar + 8), size = u16(fvar + 10)
            for k in 0..<count {
                let a = first + k * size
                let lo = fixed(a + 4), standard = fixed(a + 8), hi = fixed(a + 12)
                // Hidden axes are the font's own business.
                guard u16(a + 16) & 1 == 0, lo < hi else { continue }
                let t = tag(a)
                axes.append(Fonts.Axis(tag: t, name: name(u16(a + 18)) ?? t, range: lo...hi, standard: standard))
            }
        }
        self.init(features: features, axes: axes, family: name(16) ?? name(1))
    }
}
