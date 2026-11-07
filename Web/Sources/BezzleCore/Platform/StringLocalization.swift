import Foundation

// Apple's Foundation looks words up in the app's string catalog. Here they are looked up by
// `Localization.lookup` when the host gives one (Windows does, from the Mac's catalog), by the
// key the Mac's catalog has them under: the words as written, an interpolated whole number as
// %lld and anything else as %@ (so "Rectangle \(i)" is "Rectangle %lld"), or the key given.
// Without one, or for words it does not have, they stay as written in the code, in English.

/// Where the code's words are looked up in the user's language.
nonisolated public enum Localization {
    /// The words for a key, filled with what goes into it, or nil to keep them as written.
    nonisolated(unsafe) public static var lookup: ((_ key: String, _ arguments: [Any]) -> String?)?

    /// What fills a key's %lld or %@.
    public enum Argument: Hashable, Sendable {
        case whole(Int)
        case words(String)
        var value: Any {
            switch self {
            case .whole(let n): n
            case .words(let s): s
            }
        }
    }

    static func look(_ key: String, _ arguments: [Argument], otherwise text: String) -> String {
        lookup?(key, arguments.map(\.value)) ?? text
    }
}

nonisolated public extension String {
    struct LocalizationValue: ExpressibleByStringInterpolation, Hashable, Sendable {
        /// The words as written.
        public var text: String
        /// The catalog's key for them, and what fills it.
        public var key: String
        public var arguments: [Localization.Argument]
        public init(_ text: String) { self.text = text; key = text; arguments = [] }
        public init(stringLiteral value: String) { self.init(value) }
        public init(stringInterpolation: StringInterpolation) {
            text = stringInterpolation.text
            key = stringInterpolation.key
            arguments = stringInterpolation.arguments
        }

        public struct StringInterpolation: StringInterpolationProtocol {
            var text = ""
            var key = ""
            var arguments: [Localization.Argument] = []
            public init(literalCapacity: Int, interpolationCount: Int) {}
            public mutating func appendLiteral(_ s: String) {
                text += s
                key += s.replacingOccurrences(of: "%", with: "%%")
            }
            public mutating func appendInterpolation<T>(_ v: T) { words("\(v)") }
            public mutating func appendInterpolation(_ v: String) { words(v) }
            public mutating func appendInterpolation<T: BinaryInteger>(_ v: T) {
                text += "\(v)"
                key += "%lld"
                arguments.append(.whole(Int(v)))
            }
            public mutating func appendInterpolation(_ v: Double, format: FloatingPointFormatStyle<Double>) { words("\(v)") }
            private mutating func words(_ s: String) {
                text += s
                key += "%@"
                arguments.append(.words(s))
            }
        }
    }

    init(localized value: LocalizationValue, table: String? = nil, bundle: Bundle? = nil, locale: Locale = .current, comment: StaticString? = nil) {
        self = Localization.look(value.key, value.arguments, otherwise: value.text)
    }

    init(localized key: StaticString, defaultValue: LocalizationValue, table: String? = nil, bundle: Bundle? = nil, locale: Locale = .current, comment: StaticString? = nil) {
        self = Localization.look("\(key)", defaultValue.arguments, otherwise: defaultValue.text)
    }

    init(localized resource: LocalizedStringResource) {
        self = Localization.look(resource.catalogKey, resource.arguments, otherwise: resource.key)
    }
}

nonisolated public struct LocalizedStringResource: ExpressibleByStringInterpolation, Hashable, Sendable {
    /// The words as written.
    public var key: String
    /// The catalog's key for them, and what fills it.
    var catalogKey: String
    var arguments: [Localization.Argument] = []
    public init(_ key: String) { self.key = key; catalogKey = key }
    public init(stringLiteral value: String) { self.init(value) }
    public init(stringInterpolation: String.LocalizationValue.StringInterpolation) {
        let value = String.LocalizationValue(stringInterpolation: stringInterpolation)
        key = value.text
        catalogKey = value.key
        arguments = value.arguments
    }
    public init(_ key: StaticString, defaultValue: String.LocalizationValue, table: String? = nil, comment: StaticString? = nil) {
        self.key = defaultValue.text
        catalogKey = "\(key)"
        arguments = defaultValue.arguments
    }
    /// Words that are not looked up, such as a layer's own name.
    public static func verbatim(_ s: String) -> LocalizedStringResource {
        var r = LocalizedStringResource(s)
        r.catalogKey = ""
        return r
    }
}
