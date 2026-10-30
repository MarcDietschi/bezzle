import Foundation

/// Words to fill a repeat grid's cells with while the real ones are still to come: believable
/// enough that a design can be judged with them in it. Prices, dates and times are written the
/// way this Mac writes them.
nonisolated enum SampleContent: String, CaseIterable, Identifiable {
    case numbers, names, firstNames, cities, countries, jobs, companies, emails, prices, dates, times, headlines, sentences

    var id: String { rawValue }

    /// Shown in the user's language; its `key` is the English the AI is told.
    var title: LocalizedStringResource {
        switch self {
        case .numbers: "Numbers"
        case .names: "Names"
        case .firstNames: "First names"
        case .cities: "Cities"
        case .countries: "Countries"
        case .jobs: "Job titles"
        case .companies: "Companies"
        case .emails: "Email addresses"
        case .prices: "Prices"
        case .dates: "Dates"
        case .times: "Times"
        case .headlines: "Headlines"
        case .sentences: "Sentences"
        }
    }

    /// Two of what it gives, to show in a menu.
    func example(for words: String = "") -> String {
        values(2, like: words).joined(separator: ", ") + "…"
    }

    /// As many as there are cells. Numbers keep the words around a number already there, so
    /// "Step 1" is followed by "Step 2"; the rest start somewhere of their own each time.
    func values(_ count: Int, like words: String = "", seed: Int = 0) -> [String] {
        guard count > 0 else { return [] }
        var rng = Seeded(seed: UInt64(truncatingIfNeeded: seed &+ rawValue.hashValueStable))
        func pick(_ list: [String]) -> [String] {
            let start = Int(rng.next() % UInt64(list.count))
            return (0..<count).map { list[(start + $0) % list.count] }
        }
        switch self {
        case .numbers:
            if let (before, digits, after) = Series.number(in: words) {
                let first = Int(digits) ?? 1
                let width = digits.first == "0" ? digits.count : 0
                return (0..<count).map { i in
                    var d = String(first + i)
                    if d.count < width { d = String(repeating: "0", count: width - d.count) + d }
                    return "\(before)\(d)\(after)"
                }
            }
            return (1...count).map(String.init)
        case .names:
            let first = pick(Self.firstNameList), last = pick(Self.lastNameList.shuffled(using: &rng))
            return zip(first, last).map { "\($0) \($1)" }
        case .firstNames:
            return pick(Self.firstNameList)
        case .cities:
            return pick(Self.cityList)
        case .countries:
            return pick(Self.countryList)
        case .jobs:
            return pick(Self.jobList)
        case .companies:
            return pick(Self.companyList)
        case .emails:
            let first = pick(Self.firstNameList), last = pick(Self.lastNameList.shuffled(using: &rng))
            return zip(first, last).map { f, l in "\(Self.plain(f)).\(Self.plain(l))@example.com" }
        case .prices:
            let format = NumberFormatter()
            format.numberStyle = .currency
            format.locale = .current
            let endings: [Double] = [0, 0.5, 0.9, 0.95, 0]
            return (0..<count).map { _ in
                let whole = Double(5 + rng.next() % 240)
                let price = whole + endings[Int(rng.next() % UInt64(endings.count))]
                return format.string(from: NSNumber(value: price)) ?? String(format: "%.2f", price)
            }
        case .dates:
            let format = DateFormatter()
            format.locale = .current
            format.setLocalizedDateFormatFromTemplate("EEE d MMM")
            let start = Calendar.current.startOfDay(for: Date())
            return (0..<count).map { i in
                format.string(from: Calendar.current.date(byAdding: .day, value: i, to: start) ?? start)
            }
        case .times:
            let format = DateFormatter()
            format.locale = .current
            format.timeStyle = .short
            format.dateStyle = .none
            let start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
            return (0..<count).map { i in format.string(from: start.addingTimeInterval(Double(i) * 30 * 60)) }
        case .headlines:
            return pick(Self.headlineList)
        case .sentences:
            return pick(Self.sentenceList)
        }
    }

    /// A name as an email address writes it: small letters, without accents.
    private static func plain(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased().filter { $0.isLetter }
    }

    /// The same numbers every time for the same seed, so a fill can be made again the same.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let firstNameList = [
        "Anna", "Luca", "Mia", "Noah", "Sofia", "Elias", "Lea", "Jonas", "Emma", "Leon", "Amira", "Mateo", "Yuki", "Omar",
        "Chloé", "Felix", "Ingrid", "Kofi", "Lina", "Marco", "Nora", "Pablo", "Priya", "Samuel", "Zoë", "Hannah", "Arjun",
        "Elif", "Tomás", "Freya", "Malik", "Selin", "Jakob", "Aiko", "Liam", "Matilda", "Rafael", "Ines", "Daniel", "Maya",
    ]

    static let lastNameList = [
        "Keller", "Moreau", "Rossi", "Fischer", "Novak", "Andersen", "Costa", "Weber", "Laurent", "Okafor", "Tanaka",
        "Schmid", "Kowalski", "Haddad", "Bianchi", "Meier", "Lindqvist", "García", "Brunner", "Nakamura", "Dubois",
        "Hoffmann", "Silva", "Petrov", "Gerber", "Jensen", "Ferrari", "Wagner", "Martin", "Yilmaz", "Huber", "Murphy",
    ]

    static let cityList = [
        "Zürich", "Lisbon", "Kyoto", "Copenhagen", "Montréal", "Barcelona", "Melbourne", "Vienna", "Buenos Aires",
        "Seoul", "Amsterdam", "Cape Town", "Helsinki", "Lyon", "Vancouver", "Florence", "Reykjavík", "Marrakesh",
        "Oslo", "Porto", "Singapore", "Edinburgh", "Basel", "Valencia", "Istanbul", "Prague", "Wellington", "Bern",
        "Mexico City", "Stockholm", "Lucerne", "Hamburg",
    ]

    static let countryList = [
        "Switzerland", "Portugal", "Japan", "Denmark", "Canada", "Spain", "Australia", "Austria", "Argentina",
        "South Korea", "Netherlands", "South Africa", "Finland", "France", "Italy", "Iceland", "Morocco", "Norway",
        "Singapore", "Scotland", "Turkey", "Czechia", "New Zealand", "Mexico", "Sweden", "Germany", "Brazil", "Kenya",
    ]

    static let jobList = [
        "Product Designer", "Software Engineer", "Head of Marketing", "Data Analyst", "Art Director", "Project Manager",
        "UX Researcher", "Brand Strategist", "Copywriter", "Front-end Developer", "Photographer", "Architect",
        "Illustrator", "Account Manager", "Chief of Staff", "Content Editor", "Sales Lead", "Motion Designer",
        "Legal Counsel", "Operations Manager", "Customer Success", "Product Manager", "Engineering Lead", "Translator",
    ]

    static let companyList = [
        "Northwind Studio", "Bluebird & Co.", "Alder Labs", "Fieldnote", "Paper Lantern", "Kestrel Works", "Halcyon",
        "Lumen Partners", "Saltwater", "Atlas Foundry", "Moss & Stone", "Quiet Harbour", "Brightline", "Copperleaf",
        "Juniper Systems", "Meridian", "Oakridge Goods", "Riverbend", "Sundial", "Tidewater", "Vantage Point", "Wren",
    ]

    static let headlineList = [
        "A quieter way to work", "Made to last", "Small things, done well", "Everything in its place",
        "Start where you are", "The long way round", "Good light, good days", "Less, but better", "Room to think",
        "Built for the weekend", "Into the blue", "Slow mornings", "Notes from the field", "The shape of things",
        "Here comes summer", "A table for everyone", "Close to home", "Out of the ordinary", "First things first",
        "Always in season",
    ]

    static let sentenceList = [
        "Thoughtful design for everyday life, made to be used and loved for years.",
        "Everything you need to get started, and nothing you don't.",
        "Crafted from natural materials in a small workshop by the lake.",
        "A simple idea, carefully made, that quietly makes the day better.",
        "Join thousands of people who have already made the switch.",
        "Fresh ingredients, honest prices, and a seat by the window.",
        "Built with care, tested in the real world, and backed for life.",
        "Plan your week in minutes and spend the time you save outdoors.",
        "From the first sketch to the final detail, every step is ours.",
        "Light enough to carry anywhere, strong enough for every day.",
        "A calm space to read, to work, or to do nothing at all.",
        "Designed in the mountains and made to travel the world.",
    ]
}

nonisolated private extension String {
    /// A number from the words that is the same every time the app runs, unlike `hashValue`.
    var hashValueStable: Int {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in utf8 {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01B3
        }
        return Int(truncatingIfNeeded: h)
    }
}
