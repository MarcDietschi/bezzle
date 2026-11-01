import Foundation

/// Developing pictures, for the assistant: see `Develop`.
extension MCPTools {
    func developPhoto(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store).filter { store.node($0).map(DocumentStore.develops) == true }
        guard !ids.isEmpty else { throw MCPError("None of these is filled with a picture; place_image puts one in.") }
        let reset = try args.bool("reset") == true, auto = try args.bool("auto") == true

        var settings: [(Develop.Setting, Double)] = []
        for s in Develop.Setting.allCases {
            guard let v = try args.number(s.rawValue) else { continue }
            guard s.range.contains(v) else {
                throw MCPError("\(s.rawValue) runs from \(Self.said(s.range.lowerBound)) to \(Self.said(s.range.upperBound)).")
            }
            settings.append((s, v))
        }
        var bands: [(Develop.Band, [Develop.Shift.Part: Double])] = []
        if let given = args["colors"] {
            guard let colors = try Read.object(given, "colors") else { throw MCPError("colors should be {\"blue\": {\"saturation\": 20}, …}.") }
            for (name, value) in colors {
                guard let band = Develop.Band(rawValue: name.lowercased()) else {
                    throw MCPError("colors are \(Develop.Band.allCases.map(\.rawValue).joined(separator: ", ")); not \(name).")
                }
                guard let parts = try Read.object(value, "colors.\(name)") else { throw MCPError("colors.\(name) should be {hue, saturation, luminance}.") }
                var shift: [Develop.Shift.Part: Double] = [:]
                for (key, raw) in parts {
                    guard let part = Develop.Shift.Part(rawValue: key.lowercased()) else { throw MCPError("colors.\(name) takes hue, saturation and luminance; not \(key).") }
                    guard let v = try Read.number(raw, "colors.\(name).\(key)"), (-100...100).contains(v) else {
                        throw MCPError("colors.\(name).\(key) runs from -100 to 100.")
                    }
                    shift[part] = v
                }
                bands.append((band, shift))
            }
        }
        guard reset || auto || !settings.isEmpty || !bands.isEmpty else {
            throw MCPError("Give something to change: a setting such as exposure or temperature, colors, auto or reset.")
        }
        // What suits each picture best is read before anything changes.
        let suited = auto ? Dictionary(uniqueKeysWithValues: ids.compactMap { id in store.node(id).map { (id, store.autoDevelop(for: $0)) } }) : [:]
        let changed = try change(store, auto ? "Auto Photo" : reset ? "Reset Photo" : "Change Photo") { doc in
            for id in ids {
                doc.update(id) { n in
                    guard var image = n.fill.image else { return }
                    var d = reset ? Develop() : image.develop ?? Develop()
                    if auto { d = suited[id] ?? d }
                    for (s, v) in settings { d[s] = v }
                    for (band, parts) in bands { for (part, v) in parts { d[band][part] = v } }
                    image.develop = d.kept
                    n.fill.image = image
                }
            }
        }
        return described(ids, in: store, full: true, warnings: changed ? [] : ["The photos were already developed like that, so nothing changed."])
    }

    private static func said(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }

    /// A picture's development as get_layers shows it: only what is changed.
    static func describe(_ d: Develop?) -> JSONValue? {
        guard let d, !d.isNeutral else { return nil }
        var pairs: [(String, JSONValue?)] = Develop.Setting.allCases.map { s in (s.rawValue, d[s] != 0 ? .number(d[s]) : nil) }
        let colors: [(String, JSONValue?)] = Develop.Band.allCases.map { band in
            let s = d[band]
            return (band.rawValue, s.isNone ? nil : .compact(Develop.Shift.Part.allCases.map { ($0.rawValue, s[$0] != 0 ? .number(s[$0]) : nil) }))
        }
        if !d.bands.isEmpty { pairs.append(("colors", .compact(colors))) }
        return .compact(pairs)
    }
}

extension MCPTools {
    /// The develop_photo tool's definition, beside the others in `MCPDefinitions`.
    static var developDefinitionProperties: [(String, JSONValue)] {
        func number(_ d: String) -> JSONValue { ["type": "number", "description": .string(d)] }
        var props: [(String, JSONValue)] = [
            ("design", ["type": "string", "description": "Which design: its name or path. Leave it out for the one in front; one not open is opened."]),
            ("layers", ["type": "array", "items": ["type": "string"], "description": "Layers filled with photos, by id or name. Leave it out for the selection."]),
            ("reset", ["type": "boolean", "description": "Starts from the photo as it was taken, before any settings given are set."]),
            ("auto", ["type": "boolean", "description": "Starts from what suits each photo best (exposure, ends, highlights and shadows, colour cast, vibrance), before any settings given are set."]),
        ]
        let about: [Develop.Setting: String] = [
            .exposure: "Stops of light, -4 to 4; 1 is twice as bright.",
            .contrast: "-100 to 100.", .highlights: "Bright tones: below 0 holds back a bright sky, -100 to 100.",
            .shadows: "Dark tones: above 0 opens them up, -100 to 100.", .whites: "The lightest tones, towards white above 0, -100 to 100.",
            .blacks: "The darkest tones, towards black below 0, -100 to 100.",
            .temperature: "Warmer above 0, cooler below, -100 to 100.", .tint: "Towards magenta above 0, green below, -100 to 100.",
            .vibrance: "More colour where there is least, sparing skin, -100 to 100.", .saturation: "All colours stronger or weaker; -100 is black and white.",
            .clarity: "Local contrast in the middle tones, -100 (soft glow) to 100.", .texture: "Fine detail such as skin, bark and fabric, -100 (smoother) to 100.",
            .dehaze: "Takes haze away above 0, adds it below, -100 to 100.", .sharpness: "0 to 100.",
        ]
        for s in Develop.Setting.allCases { props.append((s.rawValue, number(about[s] ?? ""))) }
        props.append(("colors", ["type": "object", "description": .string("Each colour of the photo on its own: \(Develop.Band.allCases.map(\.rawValue).joined(separator: ", ")), each {hue: turned towards the next colour round the wheel above 0 or the one before below, saturation, luminance}, -100 to 100. {\"blue\": {\"saturation\": 30, \"luminance\": -25}} deepens a sky.")]))
        return props
    }
}
