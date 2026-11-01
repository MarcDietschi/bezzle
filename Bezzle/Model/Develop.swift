import Foundation

/// How a picture is developed, as in a darkroom: its light, its colours and its detail. Each is an
/// amount away from the picture as it was taken, and 0 leaves it as it was, so an untouched
/// picture keeps nothing here at all. It is kept with the picture's fill, and the picture itself
/// never changes: taking the amounts away has it back. `Developer` makes the picture shown.
nonisolated struct Develop: Hashable, Sendable {
    /// One thing a picture's development sets.
    enum Setting: String, CaseIterable, Sendable {
        case exposure, contrast, highlights, shadows, whites, blacks
        case temperature, tint, vibrance, saturation
        case clarity, texture, dehaze, sharpness

        /// How far it goes: in stops for exposure, and from -100 to 100 for the rest, but for
        /// sharpness, which a picture only gains.
        var range: ClosedRange<Double> {
            switch self {
            case .exposure: -4...4
            case .sharpness: 0...100
            default: -100...100
            }
        }

        var group: Group {
            switch self {
            case .exposure, .contrast, .highlights, .shadows, .whites, .blacks: .light
            case .temperature, .tint, .vibrance, .saturation: .color
            case .clarity, .texture, .dehaze, .sharpness: .detail
            }
        }

        /// The steps it is set in: hundredths of a stop, or whole amounts.
        var step: Double { self == .exposure ? 0.01 : 1 }

        var title: LocalizedStringResource {
            switch self {
            case .exposure: "Exposure"
            case .contrast: "Contrast"
            case .highlights: "Highlights"
            case .shadows: "Shadows"
            case .whites: "Whites"
            case .blacks: "Blacks"
            case .temperature: "Temperature"
            case .tint: "Tint"
            case .vibrance: "Vibrance"
            case .saturation: "Saturation"
            case .clarity: "Clarity"
            case .texture: "Texture"
            case .dehaze: "Dehaze"
            case .sharpness: "Sharpness"
            }
        }

        /// The tones it works on, for those that work on some tones more than others.
        var isTone: Bool { [.highlights, .shadows, .whites, .blacks].contains(self) }
    }

    /// What a picture's settings are about: its light, its colour, or its detail.
    enum Group: String, CaseIterable, Sendable {
        case light, color, detail

        var settings: [Setting] { Setting.allCases.filter { $0.group == self } }

        var title: LocalizedStringResource {
            switch self {
            case .light: LocalizedStringResource("develop.light", defaultValue: "Light")
            case .color: "Colour"
            case .detail: "Detail"
            }
        }
    }

    /// The colours a picture's colours are told apart by, each changed on its own: around the
    /// colour wheel from red.
    enum Band: String, CaseIterable, Sendable {
        case red, orange, yellow, green, aqua, blue, purple, magenta

        /// Where on the colour wheel it is most itself, in degrees from red.
        var hue: Double {
            switch self {
            case .red: 0
            case .orange: 32
            case .yellow: 60
            case .green: 118
            case .aqua: 182
            case .blue: 226
            case .purple: 274
            case .magenta: 320
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .red: "Red"
            case .orange: "Orange"
            case .yellow: "Yellow"
            case .green: "Green"
            case .aqua: "Aqua"
            case .blue: "Blue"
            case .purple: "Purple"
            case .magenta: "Magenta"
            }
        }

        private static let hues = allCases.map(\.hue)

        /// The two bands a colour of `hue` (degrees) lies between, as the first one's index and
        /// how much of it is that band's; the rest is the next band's. All of a band's own hue is
        /// its own, and it fades smoothly into its neighbours', so every hue is shared out whole.
        static func split(hue: Double) -> (index: Int, share: Double) {
            let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            let n = hues.count
            for i in 0..<n {
                let a = hues[i], b = i == n - 1 ? hues[0] + 360 : hues[i + 1]
                guard h >= a, h < b else { continue }
                return (i, 0.5 * (1 + cos(.pi * (h - a) / (b - a))))
            }
            return (0, 1)
        }

        /// How much of a colour of `hue` (degrees) is this band's.
        func weight(hue: Double) -> Double {
            let (i, share) = Band.split(hue: hue)
            let me = Band.allCases.firstIndex(of: self)!
            if me == i { return share }
            if me == (i + 1) % Band.allCases.count { return 1 - share }
            return 0
        }
    }

    /// A band's own change: its hue turned towards the next colour round the wheel or back to the
    /// one before, and how strong and how light it is. Each from -100 to 100.
    struct Shift: Hashable, Sendable {
        var hue: Double = 0
        var saturation: Double = 0
        var luminance: Double = 0

        var isNone: Bool { hue == 0 && saturation == 0 && luminance == 0 }

        enum Part: String, CaseIterable, Sendable {
            case hue, saturation, luminance

            var title: LocalizedStringResource {
                switch self {
                case .hue: "Hue"
                case .saturation: "Saturation"
                case .luminance: "Luminance"
                }
            }
        }

        subscript(_ part: Part) -> Double {
            get {
                switch part {
                case .hue: hue
                case .saturation: saturation
                case .luminance: luminance
                }
            }
            set {
                let v = min(max(newValue.rounded(), -100), 100)
                switch part {
                case .hue: hue = v
                case .saturation: saturation = v
                case .luminance: luminance = v
                }
            }
        }
    }

    /// Part of the picture shown alone for a moment, while the pointer is on what changes it: a
    /// tone, the rest sinking to grey; or a colour, the rest losing theirs. Never kept.
    enum Isolation: Hashable, Sendable {
        case tone(Setting)
        case band(Band)
    }

    private(set) var amounts: [Setting: Double] = [:]
    private(set) var bands: [Band: Shift] = [:]
    /// Shown, not kept: see `Isolation`.
    var isolate: Isolation?

    init() {}

    /// Nothing changed: the picture as it was taken.
    var isNeutral: Bool { amounts.isEmpty && bands.isEmpty }

    /// The picture's development as it is kept: nil when it changes nothing.
    var kept: Develop? {
        var d = self
        d.isolate = nil
        return d.isNeutral ? nil : d
    }

    subscript(_ setting: Setting) -> Double {
        get { amounts[setting] ?? 0 }
        set {
            let r = setting.range
            let v = (min(max(newValue, r.lowerBound), r.upperBound) / setting.step).rounded() * setting.step
            amounts[setting] = abs(v) < setting.step / 2 ? nil : v
        }
    }

    subscript(_ band: Band) -> Shift {
        get { bands[band] ?? Shift() }
        set { bands[band] = newValue.isNone ? nil : newValue }
    }

    /// Only what changes each pixel by itself: its light and colour, without the detail, which
    /// depends on the pixels around it.
    var pointOnly: Develop {
        var d = self
        for s in Group.detail.settings { d.amounts[s] = nil }
        return d
    }

    /// Whether anything about the picture's light, colour or detail is changed.
    func changes(_ group: Group) -> Bool {
        amounts.keys.contains { $0.group == group } || (group == .color && !bands.isEmpty)
    }

    /// The same, as much again times `k`: 0 is the picture as it was taken, 1 this, and more goes further.
    func scaled(by k: Double) -> Develop {
        var d = Develop()
        for (s, v) in amounts { d[s] = v * k }
        for (b, shift) in bands {
            var s = Shift()
            for part in Shift.Part.allCases { s[part] = shift[part] * k }
            d[b] = s
        }
        d.isolate = isolate
        return d
    }

    /// Part of the way from `a` to `b`.
    static func mix(_ a: Develop, _ b: Develop, _ t: Double) -> Develop {
        var d = Develop()
        for s in Setting.allCases { d[s] = a[s] + (b[s] - a[s]) * t }
        for band in Band.allCases {
            var s = Shift()
            for part in Shift.Part.allCases { s[part] = a[band][part] + (b[band][part] - a[band][part]) * t }
            d[band] = s
        }
        return d
    }

    /// An angle in degrees, brought to -180…180.
    static func turn(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    // MARK: Said in words

    /// What it does to the picture, in a word or two for each of light, colour and detail, as the
    /// folded card says it: "Brighter · Warmer · Crisper".
    var words: [LocalizedStringResource] {
        var said: [LocalizedStringResource] = []
        // Light: whether it comes out brighter or darker overall, else whether it has more contrast or less.
        let lift = self[.exposure] * 40 + self[.shadows] * 0.35 + self[.highlights] * 0.25 + self[.whites] * 0.25 + self[.blacks] * 0.2
        if abs(lift) >= 6 {
            said.append(lift > 0 ? "Brighter" : "Darker")
        } else if self[.contrast] != 0 || self[.whites] - self[.blacks] != 0 || self[.highlights] != 0 || self[.shadows] != 0 {
            let punch = self[.contrast] + (self[.whites] - self[.blacks]) * 0.5 - (self[.shadows] - self[.highlights]) * 0.3
            if abs(punch) >= 4 { said.append(punch > 0 ? "Punchier" : "Flatter") } else if changes(.light) { said.append("Light tuned") }
        } else if changes(.light) {
            said.append(lift > 0 ? "Brighter" : "Darker")
        }
        // Colour: warmer or cooler, else richer or more muted, else its colours tuned.
        let richness = self[.saturation] + self[.vibrance] * 0.7
        if abs(self[.temperature]) >= 8 {
            said.append(self[.temperature] > 0 ? "Warmer" : "Cooler")
        } else if abs(richness) >= 8 {
            said.append(richness > 0 ? "Richer" : "Muted")
        } else if abs(self[.tint]) >= 8 {
            said.append(self[.tint] > 0 ? "Pinker" : "Greener")
        } else if changes(.color) {
            said.append("Colours tuned")
        }
        // Detail: clearer through haze, crisper or softer.
        let crisp = self[.clarity] + self[.texture] * 0.8 + self[.sharpness] * 0.6
        if abs(self[.dehaze]) >= abs(crisp) * 0.8, self[.dehaze] != 0 {
            said.append(self[.dehaze] > 0 ? "Clearer" : "Hazier")
        } else if crisp != 0 {
            said.append(crisp > 0 ? "Crisper" : "Softer")
        }
        return said
    }
}

// MARK: - Kept in files

/// Kept as plain numbers by name, only those that change something, so a file says just what was
/// done: `{"exposure": 0.6, "temperature": 12, "colors": {"blue": [0, 20, -15]}}`. Names it does
/// not know are passed over, so a file from a later Bezzle still opens.
nonisolated extension Develop: Codable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        self.init()
        for s in Setting.allCases {
            if let v = try c.decodeIfPresent(Double.self, forKey: Key(s.rawValue)) { self[s] = v }
        }
        if let colors = try c.decodeIfPresent([String: [Double]].self, forKey: Key("colors")) {
            for (name, v) in colors {
                guard let band = Band(rawValue: name) else { continue }
                var shift = Shift()
                for (i, part) in Shift.Part.allCases.enumerated() where i < v.count { shift[part] = v[i] }
                self[band] = shift
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        for s in Setting.allCases {
            if let v = amounts[s] { try c.encode(v, forKey: Key(s.rawValue)) }
        }
        if !bands.isEmpty {
            var colors: [String: [Double]] = [:]
            for (band, s) in bands { colors[band.rawValue] = [s.hue, s.saturation, s.luminance] }
            try c.encode(colors, forKey: Key("colors"))
        }
    }
}
