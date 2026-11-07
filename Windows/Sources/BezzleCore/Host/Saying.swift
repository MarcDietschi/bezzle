import Foundation

// Bezzle's own words from the core, such as what a drag measures, in the user's language: the app
// gives its lookup (Sources/Bezzle/Words.swift, the Mac's Localizable.xcstrings) as `say`, by the
// Mac's key and what fills it. Until it does, English.

extension WindowsCore {
    nonisolated(unsafe) public static var say: (_ key: String, _ args: [Any]) -> String = { key, args in
        var out = key, i = 0
        for token in ["%lld", "%@"] {
            while let r = out.range(of: token), i < args.count {
                out.replaceSubrange(r, with: "\(args[i])")
                i += 1
            }
        }
        return out
    }

    static func say(_ key: String, _ args: Any...) -> String {
        // The hook by name: called as `say(key, args)`, with nothing to fill in, this would be
        // taken for itself, and call itself for ever.
        let words: (_ key: String, _ args: [Any]) -> String = say
        return words(key, args)
    }
}
