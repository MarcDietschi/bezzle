import Foundation

// Developing photos on Windows, as the Mac's Photo card and its store do it (Views/PhotoCard.swift,
// Store/DevelopOperations.swift): each picture layer's `Develop`, shared, its settings and its
// colours' shifts set, all of it made stronger or weaker at once, or taken away.

extension WindowsCore {
    /// The Photo card of the selected layers, when every one is filled with a picture.
    public struct PhotoLook: Sendable {
        /// What the card says folded: "Original", what was done, or "Several".
        public let summary: String
        /// Whether none of them is developed at all.
        public let neutral: Bool
        /// Each setting's amount on the first, by its name, and whether they differ.
        public let amounts: [String: Double]
        public let mixed: Set<String>
        /// Each colour's shift on the first: hue, saturation, luminance.
        public let bands: [String: (hue: Double, saturation: Double, luminance: Double)]
        public let mixedBands: Set<String>
    }

    /// A setting, as the card shows it: its name, its title, how far it goes, which tab it is in,
    /// and how many decimals it is shown with.
    public struct PhotoSetting: Sendable {
        public let name: String
        public let title: String
        public let low: Double
        public let high: Double
        public let group: String
        public let decimals: Int
        public let isTone: Bool
    }

    public static var photoSettings: [PhotoSetting] {
        Develop.Setting.allCases.map { s in
            PhotoSetting(name: s.rawValue, title: String(localized: s.title), low: s.range.lowerBound, high: s.range.upperBound,
                         group: s.group.rawValue, decimals: s == .exposure ? 2 : 0, isTone: s.isTone)
        }
    }

    /// The tabs: their names and titles.
    public static var photoGroups: [(name: String, title: String)] {
        Develop.Group.allCases.map { ($0.rawValue, String(localized: $0.title)) }
    }

    /// The colours, by name: their titles and where each is most itself on the wheel, in degrees.
    public static var photoBands: [(name: String, title: String, hue: Double)] {
        Develop.Band.allCases.map { ($0.rawValue, String(localized: $0.title), $0.hue) }
    }

    private static func develops(_ n: Node) -> Bool { n.fill.on && n.fill.image != nil }

    public static func photoLook(_ ids: [UUID]) -> PhotoLook? {
        guard let doc = design else { return nil }
        let nodes = ids.compactMap { doc.node($0) }
        guard let first = nodes.first, nodes.count == ids.count, nodes.allSatisfy(develops) else { return nil }
        let developments = nodes.map { $0.fill.image?.develop }
        let d = first.fill.image?.develop ?? Develop()
        let alike = Set(developments).count == 1
        let summary = !alike ? say("Several") : d.isNeutral ? say("Original") : d.words.map { String(localized: $0) }.joined(separator: " · ")
        var amounts: [String: Double] = [:], mixed = Set<String>()
        for s in Develop.Setting.allCases {
            amounts[s.rawValue] = d[s]
            if Set(developments.map { ($0 ?? Develop())[s] }).count > 1 { mixed.insert(s.rawValue) }
        }
        var bands: [String: (Double, Double, Double)] = [:], mixedBands = Set<String>()
        for b in Develop.Band.allCases {
            let shift = d[b]
            bands[b.rawValue] = (shift.hue, shift.saturation, shift.luminance)
            if Set(developments.map { ($0 ?? Develop())[b] }).count > 1 { mixedBands.insert(b.rawValue) }
        }
        return PhotoLook(summary: summary, neutral: developments.allSatisfy { $0 == nil }, amounts: amounts, mixed: mixed,
                         bands: bands, mixedBands: mixedBands)
    }

    /// Each picture layer's development changed, as one step, or as the gesture stands.
    private static func develop(_ ids: [UUID], _ change: @escaping (inout Develop) -> Void) {
        edit { doc in
            for id in ids {
                guard let n = doc.node(id), develops(n) else { continue }
                doc.update(id) { n in
                    guard var image = n.fill.image else { return }
                    var d = image.develop ?? Develop()
                    change(&d)
                    image.develop = d.kept
                    n.fill.image = image
                }
            }
        }
    }

    /// A setting set, by its name.
    public static func setPhoto(_ ids: [UUID], _ name: String, _ value: Double) {
        guard let s = Develop.Setting(rawValue: name) else { return }
        develop(ids) { $0[s] = value }
    }

    /// A colour's hue, saturation or luminance set (`part`: "hue", "saturation", "luminance").
    public static func setPhotoBand(_ ids: [UUID], _ band: String, _ part: String, _ value: Double) {
        guard let b = Develop.Band(rawValue: band), let p = Develop.Shift.Part(rawValue: part) else { return }
        develop(ids) { $0[b][p] = value }
    }

    /// Back to the photo as it was taken.
    public static func resetPhoto(_ ids: [UUID]) {
        develop(ids) { $0 = Develop() }
    }

    /// How much of the development there is, as a share of what there was as the drag began, from
    /// nothing to twice as much (the folded card's drag). A photo not yet developed has nothing to
    /// make more of yet: it stays as it is until Auto is here.
    public static func photoStrength(_ ids: [UUID], _ k: Double) {
        let start = Editing.gestureStart ?? design
        edit { doc in
            for id in ids {
                guard let n = doc.node(id), develops(n) else { continue }
                let was = start?.node(id)?.fill.image?.develop ?? Develop()
                guard !was.isNeutral else { continue }
                doc.update(id) { $0.fill.image?.develop = was.scaled(by: k).kept }
            }
        }
    }
}
