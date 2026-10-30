import Foundation

/// Bezzle speaks English, German, French and Italian. Its words are in Localizable.xcstrings:
/// a literal passed where a `LocalizedStringResource` is expected, as the titles of its controls
/// and menus and the names of undo steps are, is found there by the build and translated.
extension LocalizedStringResource {
    /// Shows text as it is where a translated title is expected, such as a layer's or a font's name.
    /// (The catalog marks the "%@" this makes as not to be translated.)
    nonisolated static func verbatim(_ text: String) -> LocalizedStringResource {
        "\(text)"
    }
}
