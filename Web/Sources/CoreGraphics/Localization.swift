import Foundation

// Apple's Foundation looks words up in the app's string catalog; here, for now, they stay as
// written in the code, in English.

public extension String {
    struct LocalizationValue: ExpressibleByStringInterpolation, Hashable, Sendable {
        public var text: String
        public init(_ text: String) { self.text = text }
        public init(stringLiteral value: String) { text = value }
        public init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }

        public struct StringInterpolation: StringInterpolationProtocol {
            var text = ""
            public init(literalCapacity: Int, interpolationCount: Int) {}
            public mutating func appendLiteral(_ s: String) { text += s }
            public mutating func appendInterpolation<T>(_ v: T) { text += "\(v)" }
            public mutating func appendInterpolation(_ v: String) { text += v }
            public mutating func appendInterpolation<T: BinaryInteger>(_ v: T) { text += "\(v)" }
            public mutating func appendInterpolation(_ v: Double, format: FloatingPointFormatStyle<Double>) { text += "\(v)" }
        }
    }

    init(localized value: LocalizationValue, table: String? = nil, bundle: Bundle? = nil, locale: Locale = .current, comment: StaticString? = nil) {
        self = value.text
    }

    init(localized key: StaticString, defaultValue: LocalizationValue, table: String? = nil, bundle: Bundle? = nil, locale: Locale = .current, comment: StaticString? = nil) {
        self = defaultValue.text
    }

    init(localized resource: LocalizedStringResource) { self = resource.key }
}

public struct LocalizedStringResource: ExpressibleByStringInterpolation, Hashable, Sendable {
    public var key: String
    public init(_ key: String) { self.key = key }
    public init(stringLiteral value: String) { key = value }
    public init(stringInterpolation: String.LocalizationValue.StringInterpolation) { key = String.LocalizationValue(stringInterpolation: stringInterpolation).text }
    public init(_ key: StaticString, defaultValue: String.LocalizationValue, table: String? = nil, comment: StaticString? = nil) { self.key = defaultValue.text }
    public static func verbatim(_ s: String) -> LocalizedStringResource { LocalizedStringResource(s) }
}
