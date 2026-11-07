import Foundation
import CoreGraphics

// What the Text card shows of text layers, and how it changes them, shared by every Bezzle: the
// Mac's TextCard and the Windows one sum the layers up alike, match faces across families alike
// and turn a font's features on and off alike. What each platform answers for itself: a family's
// faces, how heavy a face is and whether it leans (`Fonts.traits`), and a font's own line height.

/// What text layers have alike, as the Text card shows it: nil where they differ.
struct TextSummary {
    /// The layers, and how the letters the card changes look, a run's worth each.
    let nodes: [Node]
    let letters: [Letters]

    /// `letters` defaults to every letter of the layers; while typing with letters picked out,
    /// the Mac gives those.
    init(nodes: [Node], letters: [Letters]? = nil) {
        self.nodes = nodes
        self.letters = letters ?? nodes.filter { $0.kind == .text }.flatMap { $0.letters() }
    }

    /// What every one of `items` has alike, or nil when they differ.
    static func alike<T: Equatable, I>(_ items: [I], _ value: (I) -> T) -> T? {
        guard let first = items.first.map(value) else { return nil }
        return items.allSatisfy { value($0) == first } ? first : nil
    }

    /// What the layers' own styles have alike: about the whole layer.
    func common<T: Equatable>(_ value: (TextStyle) -> T) -> T? {
        Self.alike(nodes.map { $0.style ?? TextStyle() }, value)
    }

    /// What the letters have alike.
    func letter<T: Equatable>(_ value: (Letters) -> T) -> T? { Self.alike(letters, value) }

    /// The first letters, to go on where they differ.
    var first: Letters { letters.first ?? TextLook.plain.resolved(over: TextStyle(), color: .black) }

    /// The line spacing they share, or the font's own line height until one is set.
    var lineSpacing: Double? {
        guard let set = common(\.lineSpacing) else { return nil }
        if let set { return Double(set) }
        guard let style = nodes.first?.style else { return nil }
        return Double(Fonts.naturalLineHeight(style))
    }

    /// The letter cases offered, as typed first.
    static let cases: [LetterCase?] = [nil, .upper, .lower, .title, .smallCaps]
}

/// A font's OpenType features as the Text card turns them on and off.
nonisolated enum TextFeatures {
    /// Features that are on unless turned off.
    static let onByDefault: Set<String> = ["liga", "calt"]

    /// The features the card names itself, when the font's own name says little; in the order
    /// they show, before the font's stylistic sets and then its character variants.
    static let named = ["liga", "dlig", "calt", "onum", "lnum", "tnum", "pnum", "zero", "frac", "sups", "subs", "ordn",
                        "case", "salt", "swsh", "titl"]

    static func isStylisticSet(_ tag: String) -> Bool { tag.hasPrefix("ss") && tag.count == 4 }
    static func isCharacterVariant(_ tag: String) -> Bool { tag.hasPrefix("cv") && tag.count == 4 }

    static func isOn(_ tag: String, in style: TextStyle) -> Bool {
        if let v = style.features?[tag] { return v != 0 }
        return onByDefault.contains(tag)
    }

    /// The feature turned the other way from `on`: back to how the font sets it, rather than
    /// kept, where that is what is asked.
    static func flip(_ tag: String, from on: Bool, in s: inout TextStyle) {
        var f = s.features ?? [:]
        if on == onByDefault.contains(tag) { f[tag] = on ? 0 : 1 } else { f[tag] = nil }
        s.features = f.isEmpty ? nil : f
    }

    /// How many of the font's features `style` sets otherwise than the font does.
    static func changed(in style: TextStyle, offered: Set<String>) -> Int {
        (style.features ?? [:]).filter { offered.contains($0.key) && ($0.value != 0) != onByDefault.contains($0.key) }.count
    }
}

// MARK: - Faces alike

extension Fonts {
    /// The face of `family` most like `face` of `from`: the same name if it has one, else the one
    /// nearest in weight that leans as it does.
    nonisolated static func face(like face: String, of from: String, in family: String) -> String {
        let faces = self.faces(of: family)
        if faces.contains(face) { return face }
        guard !faces.isEmpty else { return face }
        let want = traits(of: face, in: from)
        return faces.min { a, b in
            let ta = traits(of: a, in: family), tb = traits(of: b, in: family)
            let da = abs(ta.weight - want.weight) + (ta.italic == want.italic ? 0 : 20)
            let db = abs(tb.weight - want.weight) + (tb.italic == want.italic ? 0 : 20)
            return da != db ? da < db : (a == "Regular") && b != "Regular"
        } ?? face
    }

    /// The face of a family that is the bold, or not bold, of `face`, keeping whether it leans.
    nonisolated static func face(_ face: String, of family: String, bold: Bool) -> String {
        let now = traits(of: face, in: family)
        let faces = self.faces(of: family).filter { traits(of: $0, in: family).italic == now.italic }
        let goal = bold ? 9 : 5
        if bold ? now.weight >= 8 : now.weight <= 6 { return face }
        return faces.min { abs(traits(of: $0, in: family).weight - goal) < abs(traits(of: $1, in: family).weight - goal) } ?? face
    }

    /// The face of a family that is the leaning, or upright, `face`, keeping its weight.
    nonisolated static func face(_ face: String, of family: String, italic: Bool) -> String {
        let now = traits(of: face, in: family)
        guard now.italic != italic else { return face }
        let faces = self.faces(of: family).filter { traits(of: $0, in: family).italic == italic }
        return faces.min { abs(traits(of: $0, in: family).weight - now.weight) < abs(traits(of: $1, in: family).weight - now.weight) } ?? face
    }

    nonisolated static func isBold(_ face: String, of family: String) -> Bool { traits(of: face, in: family).weight >= 8 }
    nonisolated static func isItalic(_ face: String, of family: String) -> Bool { traits(of: face, in: family).italic }

    /// How heavy a face is and whether it leans, read from its name, as the font manager counts
    /// weight (5 regular, 9 bold): for fonts known only by their names.
    nonisolated static func traits(named face: String) -> (weight: Int, italic: Bool) {
        let words = face.lowercased().replacingOccurrences(of: "-", with: " ")
        let italic = words.contains("italic") || words.contains("oblique")
        let squeezed = words.replacingOccurrences(of: " ", with: "")
        // Longest first, so "extrabold" is not read as "bold".
        let weights: [(String, Int)] = [
            ("extrablack", 12), ("ultrablack", 12), ("ultralight", 2), ("extralight", 2), ("hairline", 1),
            ("extrabold", 10), ("ultrabold", 10), ("semibold", 8), ("demibold", 8), ("black", 11), ("heavy", 10),
            ("bold", 9), ("medium", 6), ("light", 4), ("thin", 3), ("book", 5), ("regular", 5), ("roman", 5),
        ]
        let weight = weights.first { squeezed.contains($0.0) }?.1 ?? 5
        return (weight, italic)
    }
}
