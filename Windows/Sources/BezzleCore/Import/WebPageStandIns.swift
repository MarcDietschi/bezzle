import Foundation

// What the Mac's reading of web pages (WebImporter.swift beside this, linked from Bezzle/Import)
// takes from AppKit and Text Kit that the importers' stand-ins (ImportStandIns.swift) do not have.

/// What kind of face a font is, as the font manager lists its members (see NSFontManager in the
/// web core's AppKit stand-in, which reads it from the face's name).
nonisolated struct NSFontTraitMask: OptionSet, Sendable {
    let rawValue: UInt

    static let italicFontMask = NSFontTraitMask(rawValue: 0x1)
    static let boldFontMask = NSFontTraitMask(rawValue: 0x2)
    static let narrowFontMask = NSFontTraitMask(rawValue: 0x10)
    static let expandedFontMask = NSFontTraitMask(rawValue: 0x20)
    static let condensedFontMask = NSFontTraitMask(rawValue: 0x40)
    static let compressedFontMask = NSFontTraitMask(rawValue: 0x200)
}

extension TextLayout.Laid {
    /// What Text Kit lays a text's words out in: one a text, here as on the Mac.
    var container: Int { 0 }
}

extension LaidLines {
    /// All of the text's letters, as Text Kit's glyphs in its one container.
    func glyphRange(for container: Int) -> NSRange {
        NSRange(location: 0, length: lines.last?.end ?? 0)
    }

    /// Each line the text is laid out in, as Text Kit's line fragments, top first.
    func enumerateLineFragments(forGlyphRange range: NSRange, using block: (CGRect, CGRect, Int, NSRange, UnsafeMutablePointer<Bool>) -> Void) {
        var stop = false
        for line in lines where line.end > range.location && line.start < range.location + range.length {
            let rect = CGRect(x: 0, y: line.top, width: line.width, height: line.height)
            block(rect, rect, 0, NSRange(location: line.start, length: line.end - line.start), &stop)
            if stop { return }
        }
    }
}
