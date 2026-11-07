import Foundation
import WinSDK

/// Bezzle's words in the language Windows is set to, as the Mac's (Bezzle/Localizable.xcstrings,
/// made into strings.json beside the app by Resources/make-strings.py): German, French and
/// Italian, else English. `BEZZLE_LANGUAGE=de` chooses one, for trying.
///
/// Only Bezzle's own words go through here, never what someone has written or named, so a layer
/// called "Fill" stays "Fill".
enum Words {
    /// A word, or a plural's forms by the number they are for ("one", "other").
    private enum Entry {
        case word(String)
        case plural([String: String])
    }

    /// The language the words are in: "de", "fr", "it", or "en".
    static let language: String = {
        if let chosen = ProcessInfo.processInfo.environment["BEZZLE_LANGUAGE"], ["de", "fr", "it", "en"].contains(chosen) { return chosen }
        // The primary language of the user's interface: German 0x07, French 0x0C, Italian 0x10.
        switch Int(GetUserDefaultUILanguage()) & 0x3FF {
        case 0x07: return "de"
        case 0x0C: return "fr"
        case 0x10: return "it"
        default: return "en"
        }
    }()

    private static let table: [String: Entry] = {
        // English has only its plurals there ("1 artboard"): the code's words are English.
        let file = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("strings.json")
        guard let data = try? Data(contentsOf: file),
              let all = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mine = all[language] as? [String: Any] else { return [:] }
        var out: [String: Entry] = [:]
        for (key, value) in mine {
            if let s = value as? String { out[key] = .word(s) }
            else if let forms = value as? [String: String] { out[key] = .plural(forms) }
        }
        // The Mac's keys name its keys by their symbols: here they are Windows' words, so
        // "Hold ⌥ to wipe pieces away." is found as "Hold Alt to wipe pieces away.". A shortcut
        // after two spaces is Windows' own, so the words before it are found by themselves.
        for (key, value) in mine {
            guard case .word(var s)? = out[key] else { continue }
            var k = key
            if let at = k.range(of: "  ", options: .backwards), let sat = s.range(of: "  ", options: .backwards),
               k[at.upperBound...].unicodeScalars.allSatisfy({ "⌘⌥⇧⌃↩⌫⎋".unicodeScalars.contains($0) || $0.properties.isUppercase || "0123456789,.;=+-[]/'".unicodeScalars.contains($0) }) {
                k = String(k[..<at.lowerBound])
                s = String(s[..<sat.lowerBound])
                if out[k] == nil { out[k] = .word(s) }
            }
            let windows = keysAsWords(k)
            if windows != k, out[windows] == nil { out[windows] = .word(keysAsWords(s)) }
            _ = value
        }
        return out
    }()

    /// The Mac's key symbols as Windows names its keys, and the Option key's name, in each
    /// language, as Windows' Alt.
    private static func keysAsWords(_ s: String) -> String {
        var s = s.replacingOccurrences(of: "⌘", with: "Ctrl").replacingOccurrences(of: "⌥", with: "Alt")
            .replacingOccurrences(of: "⇧", with: "Shift").replacingOccurrences(of: "⌃", with: "Ctrl")
            .replacingOccurrences(of: "↩", with: "Enter")
        for (mac, windows) in [("Wahltaste", "Alt-Taste"), ("Opzione", "Alt"), ("Option", "Alt")] {
            s = s.replacingOccurrences(of: mac, with: windows)
        }
        return s
    }

    /// Words the Mac keeps under a name of their own rather than their English.
    private static let named: [String: String] = [
        "Centred": "border.centred", "Prototype": "mode.prototype", "Inspect": "mode.inspect", "Variable Font": "text.axes",
        "Curve": "curve.title", "On Path": "curve.on-path", "Dip": "curve.dip", "Arch": "curve.arch", "Half circle": "curve.half",
        "Goes To": "flow.card", "Screen": "screen.card", "States": "states.card",
        "Put Text on Path": "undo.text-on-path", "Straighten Text": "undo.straighten-text", "Take Text off Path": "undo.take-text-off-path",
        "Release Mask": "undo.release-mask", "Take Out of Mask": "undo.take-out-of-mask",
    ]

    /// One of Bezzle's words, as it reads in the language.
    static func t(_ english: String) -> String {
        if table[english] == nil, let key = named[english], table[key] != nil { return t(key) }
        switch table[english] {
        case .word(let s)?: return s
        case .plural(let forms)?: return forms["other"] ?? english
        case nil:
            // Words, then Windows' shortcut after two spaces: the words alone, and the shortcut as it is.
            if let at = english.range(of: "  ", options: .backwards), case .word(let s)? = table[String(english[..<at.lowerBound])] {
                return s + english[at.lowerBound...]
            }
            return english
        }
    }

    /// Words with numbers or names in them, by the Mac's key: `%lld` for a whole number, `%@`
    /// for words, `%.1f` and the like for a fraction, in order or by place (`%2$@`). The first
    /// whole number chooses the plural's form.
    static func t(_ key: String, _ args: Any...) -> String {
        let count = args.lazy.compactMap { $0 as? Int }.first
        var template = key
        switch table[key] {
        case .word(let s)?: template = s
        case .plural(let forms)?: template = forms[pluralForm(count ?? 0)] ?? forms["other"] ?? key
        case nil: break
        }
        return fill(template, args)
    }

    /// The same, with what fills it given as a list (the core's `WindowsCore.say`).
    static func t(_ key: String, arguments args: [Any]) -> String {
        let count = args.lazy.compactMap { $0 as? Int }.first
        var template = key
        switch table[key] {
        case .word(let s)?: template = s
        case .plural(let forms)?: template = forms[pluralForm(count ?? 0)] ?? forms["other"] ?? key
        case nil: break
        }
        return fill(template, args)
    }

    /// The shared code's own words by the Mac's key (`Localization.lookup`, as `String(localized:)`
    /// asks): in the language, or nil for English and for words it does not have, which stay as
    /// the code writes them.
    static func lookup(_ key: String, _ args: [Any]) -> String? {
        guard language != "en", !key.isEmpty, table[key] != nil else { return nil }
        return t(key, arguments: args)
    }

    /// Words the shared model put together in English (`String(localized:)` finds no other
    /// language on Windows), such as "All 2 copies" or "Variant 3": found by the Mac's key they
    /// were made from, numbers and names taken out and put into the words in the language. As
    /// they are, when no key makes them.
    static func match(_ shown: String) -> String {
        guard language != "en" else { return shown }
        if table[shown] != nil { return t(shown) }
        for (key, pattern) in patterns {
            guard let m = pattern.firstMatch(in: shown, range: NSRange(shown.startIndex..., in: shown)), m.numberOfRanges > 1 else { continue }
            var args: [Any] = []
            for i in 1..<m.numberOfRanges {
                guard let r = Range(m.range(at: i), in: shown) else { continue }
                let piece = String(shown[r])
                // A name the model made inside it, such as a default variant's, as well.
                args.append(Int(piece) ?? match(piece))
            }
            return t(key, arguments: args)
        }
        return shown
    }

    /// Each key with something to fill in, as a pattern of its English: whole numbers for %lld
    /// and words for %@, in order. Made once.
    private static let patterns: [(String, NSRegularExpression)] = {
        var out: [(String, NSRegularExpression)] = []
        for key in table.keys where key.contains("%lld") || key.contains("%@") {
            guard !key.contains("$") else { continue }
            var pattern = "^"
            var rest = Substring(key)
            while let at = rest.firstIndex(of: "%") {
                pattern += NSRegularExpression.escapedPattern(for: String(rest[..<at]))
                let after = rest[at...]
                if after.hasPrefix("%lld") { pattern += "(-?\\d+)"; rest = after.dropFirst(4) }
                else if after.hasPrefix("%@") { pattern += "(.+?)"; rest = after.dropFirst(2) }
                else { pattern += "%"; rest = after.dropFirst() }
            }
            pattern += NSRegularExpression.escapedPattern(for: String(rest)) + "$"
            if let re = try? NSRegularExpression(pattern: pattern) { out.append((key, re)) }
        }
        // The longest first, so "Only in this copy" is not taken for "Only %@".
        return out.sorted { $0.0.count > $1.0.count }
    }()

    /// Which form a number takes: in French nought and one are both singular.
    private static func pluralForm(_ n: Int) -> String {
        if n == 1 || (language == "fr" && n == 0) { return "one" }
        return "other"
    }

    private static func fill(_ template: String, _ args: [Any]) -> String {
        var out = "", next = 0
        var rest = Substring(template)
        while let percent = rest.firstIndex(of: "%") {
            out += rest[..<percent]
            var i = rest.index(after: percent)
            guard i < rest.endIndex else { out += "%"; rest = rest[i...]; break }
            if rest[i] == "%" { out += "%"; rest = rest[rest.index(after: i)...]; continue }
            // A place, as in %2$@.
            var digits = ""
            var j = i
            while j < rest.endIndex, rest[j].isNumber { digits.append(rest[j]); j = rest.index(after: j) }
            var place: Int?
            if !digits.isEmpty, j < rest.endIndex, rest[j] == "$" { place = Int(digits).map { $0 - 1 }; i = rest.index(after: j) }
            // Flags, width and precision, then the kind.
            var spec = ""
            while i < rest.endIndex, "0123456789.-+ ".contains(rest[i]) { spec.append(rest[i]); i = rest.index(after: i) }
            while i < rest.endIndex, "lhqz".contains(rest[i]) { i = rest.index(after: i) }
            guard i < rest.endIndex else { break }
            let kind = rest[i]
            rest = rest[rest.index(after: i)...]
            let k = place ?? next
            if place == nil { next += 1 }
            let value: Any = k < args.count ? args[k] : ""
            switch kind {
            case "d", "i", "u":
                out += "\((value as? Int) ?? Int((value as? Double) ?? 0))"
            case "f":
                let d = (value as? Double) ?? Double((value as? Int) ?? 0)
                let digitsAfter = spec.split(separator: ".").last.flatMap { spec.contains(".") ? Int($0) : nil } ?? 6
                out += String(format: "%.\(digitsAfter)f", d)
            default:
                out += "\(value)"
            }
        }
        return out + rest
    }
}
