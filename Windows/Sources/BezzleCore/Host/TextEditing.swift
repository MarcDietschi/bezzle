import Foundation

// The Text card on Windows, as the Mac's TextCard: what the selected text layers have alike (the
// shared `TextSummary`), what their font offers, and the changes the card makes, each one step
// of the history; pointing at a choice in one of its menus shows it on the canvas first.

extension WindowsCore {
    /// What the Text card shows: nil where the layers differ.
    nonisolated public struct TextCard: Sendable {
        /// The family the letters share, as the core names it, and as it is called on screen.
        public let family: String?
        public let familyShown: String
        public let face: String?
        /// The faces of the family shown, or of the first letters' where they differ.
        public let faces: [String]
        public let size: Double?
        public let firstSize: Double
        /// left, center, right or justify.
        public let align: String?
        public let underline: Bool
        public let strikethrough: Bool
        /// bullet or number, when every letter is in a list of that kind.
        public let list: String?
        /// How the letters are set ("" as typed), nil where they differ.
        public let letterCase: String?
        /// autoWidth, autoHeight or fixed.
        public let sizing: String?
        /// top, middle or bottom, for boxes of fixed size.
        public let vertical: String?
        public let lineSpacing: Double?
        public let tracking: Double?
        public let paragraphSpacing: Double?
        public let features: [TextFeature]
        /// How many of them are set otherwise than the font sets them.
        public let featuresChanged: Int
        public let axes: [TextAxis]
        /// Whether a variable font's axes are set, which shows them open.
        public let axesSet: Bool
        /// How many letters are picked out while typing, which the letters' controls change
        /// alone; nil with none, when they change the whole layer.
        public var picked: Int?
    }

    nonisolated public struct TextFeature: Sendable {
        public let tag: String
        /// What it is called: the card's own name for the well-known ones, else the font's.
        public let name: String
        public let on: Bool
        /// 0 the well-known ones, 1 stylistic sets, 2 character variants.
        public let group: Int
    }

    nonisolated public struct TextAxis: Sendable {
        public let tag: String
        public let name: String
        public let low: Double
        public let high: Double
        /// Where the layers have it set, or the font's own.
        public let value: Double
    }

    /// A change the Text card makes.
    public enum TextChange: Sendable {
        case family(String), face(String), size(Double), tracking(Double)
        case underline(Bool), strikethrough(Bool), list(String?)
        case align(String), letterCase(String?), sizing(String), vertical(String)
        case lineSpacing(Double), paragraphSpacing(Double)
        case feature(String, from: Bool), axis(String, Double)
    }

    /// What the card calls the well-known features, as the Mac's TextCard does.
    private static let featureNames: [String: String] = [
        "liga": "Ligatures", "dlig": "Rare Ligatures", "calt": "Contextual Alternates",
        "onum": "Old-Style Figures", "lnum": "Lining Figures", "tnum": "Tabular Figures", "pnum": "Proportional Figures",
        "zero": "Slashed Zero", "frac": "Fractions", "sups": "Superscript", "subs": "Subscript", "ordn": "Ordinals",
        "case": "Case-Sensitive Forms", "salt": "Stylistic Alternates", "swsh": "Swashes", "titl": "Titling Forms",
    ]

    public static func textCard(_ ids: [UUID]) -> TextCard? {
        guard let doc = design else { return nil }
        let nodes = ids.compactMap { doc.node($0) }
        guard !nodes.isEmpty, nodes.allSatisfy({ $0.kind == .text }) else { return nil }
        // While typing, the letters picked out, as the Mac's lettersShown.
        let picked = typingInto(ids) ? pickedLetters : nil
        let sum = TextSummary(nodes: nodes, letters: picked.map { nodes[0].letters(in: $0) })
        let family = sum.letter(\.family), first = sum.first
        let style = nodes[0].style ?? TextStyle()
        let offered = Fonts.features(of: style)
        let has = Set(offered.map(\.tag))
        var features = TextFeatures.named.filter(has.contains).map {
            TextFeature(tag: $0, name: featureNames[$0] ?? $0, on: TextFeatures.isOn($0, in: style), group: 0)
        }
        features += offered.filter { TextFeatures.isStylisticSet($0.tag) }.map { TextFeature(tag: $0.tag, name: $0.name, on: TextFeatures.isOn($0.tag, in: style), group: 1) }
        features += offered.filter { TextFeatures.isCharacterVariant($0.tag) }.map { TextFeature(tag: $0.tag, name: $0.name, on: TextFeatures.isOn($0.tag, in: style), group: 2) }
        let axes = Fonts.axes(of: style).map { a in
            TextAxis(tag: a.tag, name: a.name, low: a.range.lowerBound, high: a.range.upperBound,
                     value: (sum.common { $0.axes?[a.tag] } ?? nil) ?? a.standard)
        }
        let letterCase = sum.common(\.letterCase).map { $0?.rawValue ?? "" }
        var card = TextCard(
            family: family, familyShown: family.map(Fonts.displayName) ?? "Several fonts", face: sum.letter(\.face),
            faces: Fonts.faces(of: family ?? first.family), size: sum.letter { Double($0.size) }, firstSize: Double(first.size),
            align: sum.common(\.align)?.rawValue, underline: sum.letter(\.underline) == true, strikethrough: sum.letter(\.strikethrough) == true,
            list: (sum.letter(\.list) ?? nil)?.rawValue, letterCase: letterCase, sizing: sum.common(\.sizing)?.rawValue,
            vertical: sum.common(\.sizing) == .fixed ? sum.common { ($0.vertical ?? .top).rawValue } : nil,
            lineSpacing: sum.lineSpacing, tracking: sum.letter { Double($0.tracking) },
            paragraphSpacing: sum.common { Double($0.paragraphSpacing ?? 0) },
            features: features, featuresChanged: TextFeatures.changed(in: style, offered: has),
            axes: axes, axesSet: sum.common { $0.axes != nil } != false)
        card.picked = picked?.length
        return card
    }

    /// The families the fonts menu offers, the system font first, and what each is called.
    public static var fontFamilies: [String] { Fonts.families }
    public static func displayName(_ family: String) -> String { Fonts.displayName(family) }
    public static func faces(of family: String) -> [String] { Fonts.faces(of: family) }

    /// The file a family's regular face is in, by its name in the fonts folder, and the family
    /// the file names itself: for the fonts menu to show each family in itself.
    public static func fontLook(of family: String) -> (file: String, family: String)? {
        let url: URL?
        if family == TextStyle.system {
            url = Fonts.files["System/"]
        } else {
            let faces = Fonts.faces(of: family)
            let face = faces.first { Fonts.traits(named: $0) == (5, false) } ?? faces.first ?? ""
            url = Fonts.files["\(family)/\(face)"]
        }
        guard let url, let own = Fonts.file(at: url).family else { return nil }
        return (url.lastPathComponent, own)
    }

    /// Makes a change to the selected text layers, one step of the history. While typing, what
    /// is about letters goes to the letters picked out alone, as one change of the typing.
    public static func change(_ ids: [UUID], _ change: TextChange) {
        if let f = letterChange(change), typingInto(ids), restyleTyped(f, caret: false) { return }
        let apply = make(change, ids: ids)
        edit { d in for id in ids { d.update(id) { n in if n.kind == .text { apply(&n) } } } }
    }

    /// Shows a change on the canvas without making it, as the Mac's showPreview: a font pointed
    /// at in the fonts menu. Nil takes it away. Letters picked out while typing show what is
    /// chosen once it is, as on the Mac.
    public static func preview(_ ids: [UUID], _ change: TextChange?) {
        guard let change else { endPreview(); return }
        if letterChange(change) != nil, typingInto(ids), pickedLetters != nil { return }
        let apply = make(change, ids: ids)
        preview { d in for id in ids { d.update(id) { n in if n.kind == .text { apply(&n) } } } }
    }

    /// What a change about letters does to them: their family, face, size, letter spacing,
    /// lines under and through them and lists; nil for a change to the whole layer's style.
    private static func letterChange(_ change: TextChange) -> ((inout Letters) -> Void)? {
        switch change {
        case .family(let family):
            // The family, in the face of it most like the one the letters have.
            return { l in
                l.face = Fonts.face(like: l.face, of: l.family, in: family)
                l.family = family
            }
        case .face(let face): return { $0.face = face }
        case .size(let size): return { $0.size = CGFloat(max(1, size)) }
        case .tracking(let t): return { $0.tracking = CGFloat(t) }
        case .underline(let on): return { $0.underline = on }
        case .strikethrough(let on): return { $0.strikethrough = on }
        case .list(let kind): return { $0.list = kind.flatMap(TextList.init) }
        default: return nil
        }
    }

    /// What a change does to one layer. Letters' own looks (family, face, size, letter spacing,
    /// lines under and through, lists) change in every run; the rest in the layer's style.
    private static func make(_ change: TextChange, ids: [UUID]) -> (inout Node) -> Void {
        if let f = letterChange(change) { return { n in n.restyleLetters(in: nil, f); n.refit() } }
        func style(_ f: @escaping (inout TextStyle) -> Void) -> (inout Node) -> Void {
            { n in
                var s = n.style ?? TextStyle()
                f(&s)
                n.style = s
                n.refit()
            }
        }
        switch change {
        case .family, .face, .size, .tracking, .underline, .strikethrough, .list: return { _ in }
        case .align(let a): return style { s in if let a = TextAlign(rawValue: a) { s.align = a } }
        case .letterCase(let c): return style { $0.letterCase = c.flatMap(LetterCase.init) }
        case .sizing(let raw):
            guard let sizing = TextSizing(rawValue: raw) else { return { _ in } }
            return { n in n.setSizing(sizing) }
        case .vertical(let raw):
            // Only a box of fixed size has room for its lines to lie anywhere: it becomes one.
            let v = TextVertical(rawValue: raw)
            return style { s in
                s.sizing = .fixed
                s.vertical = v == .top ? nil : v
            }
        case .lineSpacing(let v): return style { $0.lineSpacing = CGFloat(max(0, v)) }
        case .paragraphSpacing(let v): return style { $0.paragraphSpacing = v > 0 ? CGFloat(v) : nil }
        case .feature(let tag, let on): return style { TextFeatures.flip(tag, from: on, in: &$0) }
        case .axis(let tag, let value):
            return style { s in
                var a = s.axes ?? [:]
                a[tag] = value
                s.axes = a
            }
        }
    }
}

// MARK: - Showing a change before it is made

extension WindowsCore {
    /// The design as it is, while the canvas shows a change pointed at (`preview`); saving and
    /// every real change start from it.
    nonisolated(unsafe) static var previewBase: BezzleDocument?

    static func preview(_ change: (inout BezzleDocument) -> Void) {
        guard let base = previewBase ?? design else { return }
        previewBase = base
        // Shown on the design as it is, even while looking back.
        showingVersion = false
        design = Editing.edited(base, start: nil, change)
    }

    /// Takes a change shown away again; whether one was shown. A version looked back at is no
    /// such change: it stays, and shows again once a change pointed at meanwhile is taken away.
    @discardableResult public static func endPreview() -> Bool {
        guard let base = previewBase, !showingVersion else { return false }
        design = base
        previewBase = nil
        if versions.lookingBack { timeTable.reshow() }
        return true
    }
}
