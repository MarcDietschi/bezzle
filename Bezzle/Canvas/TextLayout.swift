import AppKit
import CoreText

/// Fonts by family and face, as the Font Book names them, with the Mac's own font as "System".
enum Fonts {
    nonisolated static let systemFaces: [(String, NSFont.Weight)] = [
        ("Ultralight", .ultraLight), ("Thin", .thin), ("Light", .light), ("Regular", .regular),
        ("Medium", .medium), ("Semibold", .semibold), ("Bold", .bold), ("Heavy", .heavy), ("Black", .black),
    ]

    static let families: [String] = [TextStyle.system] + NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }

    nonisolated static func faces(of family: String) -> [String] {
        if family == TextStyle.system {
            return systemFaces.flatMap { [$0.0, "\($0.0) Italic"] }
        }
        let members = resolving.withLock { NSFontManager.shared.availableMembers(ofFontFamily: family) } ?? []
        return members.compactMap { $0.count > 1 ? $0[1] as? String : nil }
    }

    /// What a family is called on screen.
    static func displayName(_ family: String) -> String {
        family == TextStyle.system ? "SF Pro" : family
    }

    private static var previews: [String: Bool] = [:]

    /// Whether a family can spell its own name, for showing it in itself in the fonts menu. Emoji,
    /// symbols and scripts without Latin letters cannot, and would show as gaps or stand-ins.
    static func showsOwnName(_ family: String) -> Bool {
        if family == TextStyle.system { return true }
        if let known = previews[family] { return known }
        let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13)
        let ok = font.map { font in
            font.fontDescriptor.symbolicTraits.intersection(.classMask) != .classSymbolic
                && font.coveredCharacterSet.isSuperset(of: CharacterSet(charactersIn: family.replacingOccurrences(of: " ", with: "")))
        } ?? false
        previews[family] = ok
        return ok
    }

    private nonisolated struct FontKey: Hashable {
        let family: String, face: String, size: CGFloat
        let features: [String: Int]?, axes: [String: Double]?, smallCaps: Bool
    }
    /// Asked for by text drawn on several threads at once.
    private nonisolated static let cache = Shared([FontKey: NSFont]())
    /// The font manager is asked one at a time.
    private nonisolated static let resolving = NSLock()

    nonisolated static func font(_ style: TextStyle) -> NSFont {
        let key = FontKey(family: style.family, face: style.face, size: style.size, features: style.features,
                          axes: style.axes, smallCaps: style.letterCase == .smallCaps)
        if let font = cache.with({ $0[key] }) { return font }
        let font = resolving.withLock { resolve(style) }
        cache.with {
            if $0.count > 2000 { $0.removeAll() }
            $0[key] = font
        }
        return font
    }

    private nonisolated static func resolve(_ style: TextStyle) -> NSFont {
        let plain = plainFont(style)
        var settings: [[CFString: Any]] = []
        for (tag, value) in (style.features ?? [:]).sorted(by: { $0.key < $1.key }) {
            settings.append([kCTFontOpenTypeFeatureTag: tag, kCTFontOpenTypeFeatureValue: value])
        }
        if style.letterCase == .smallCaps, style.features?["smcp"] == nil, tags(of: plain).contains("smcp") {
            settings.append([kCTFontOpenTypeFeatureTag: "smcp", kCTFontOpenTypeFeatureValue: 1])
        }
        var attributes: [CFString: Any] = [:]
        if !settings.isEmpty { attributes[kCTFontFeatureSettingsAttribute] = settings }
        if let axes = style.axes, !axes.isEmpty {
            let own = Set(self.axes(of: plain).map(\.tag))
            let set = axes.filter { own.contains($0.key) }
            if !set.isEmpty {
                attributes[kCTFontVariationAttribute] = Dictionary(uniqueKeysWithValues: set.map { (NSNumber(value: code($0.key)), NSNumber(value: $0.value)) })
            }
        }
        guard !attributes.isEmpty else { return plain }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(plain.fontDescriptor as CTFontDescriptor, attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, plain.pointSize, nil) as NSFont
    }

    /// The face itself, without features or axes.
    private nonisolated static func plainFont(_ style: TextStyle) -> NSFont {
        let size = max(style.size, 1)
        if style.family == TextStyle.system {
            let italic = style.face.hasSuffix("Italic")
            let name = italic ? String(style.face.dropLast(" Italic".count)) : style.face
            let weight = systemFaces.first { $0.0 == name }?.1 ?? .regular
            let font = NSFont.systemFont(ofSize: size, weight: weight)
            guard italic else { return font }
            // Leaning, at the weight it has: a descriptor's traits alone would make it regular.
            return CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitItalic, .traitItalic).map { $0 as NSFont } ?? font
        }
        let members = NSFontManager.shared.availableMembers(ofFontFamily: style.family) ?? []
        let member = members.first { ($0.count > 1 ? $0[1] as? String : nil) == style.face } ?? members.first
        if let name = member?.first as? String, let font = NSFont(name: name, size: size) { return font }
        return NSFont(name: style.family, size: size) ?? NSFont.systemFont(ofSize: size)
    }

    // MARK: Faces alike

    /// How heavy a face is and whether it leans, as the font manager counts weight: 5 regular, 9 bold.
    nonisolated static func traits(of face: String, in family: String) -> (weight: Int, italic: Bool) {
        var style = TextStyle()
        style.family = family
        style.face = face
        style.size = 12
        let font = self.font(style)
        let weight = resolving.withLock { NSFontManager.shared.weight(of: font) }
        return (weight, font.fontDescriptor.symbolicTraits.contains(.italic))
    }

    /// The face of `family` most like `face` of `from`: the same name if it has one, else the one
    /// nearest in weight that leans as it does.
    nonisolated static func face(like face: String, of from: String, in family: String) -> String {
        let faces = self.faces(of: family)
        if faces.contains(face) { return face }
        guard !faces.isEmpty else { return face }
        let want = traits(of: face, in: from)
        return faces.min { a, b in
            let ta = traits(of: a, in: family), tb = traits(of: b, in: family)
            let da = abs(ta.weight - want.weight) + (ta.italic == want.italic ? 0 : 20)
            let db = abs(tb.weight - want.weight) + (tb.italic == want.italic ? 0 : 20)
            return da != db ? da < db : (a == "Regular") && b != "Regular"
        } ?? face
    }

    /// The face of a family that is the bold, or not bold, of `face`, keeping whether it leans.
    nonisolated static func face(_ face: String, of family: String, bold: Bool) -> String {
        let now = traits(of: face, in: family)
        let faces = self.faces(of: family).filter { traits(of: $0, in: family).italic == now.italic }
        let goal = bold ? 9 : 5
        if bold ? now.weight >= 8 : now.weight <= 6 { return face }
        return faces.min { abs(traits(of: $0, in: family).weight - goal) < abs(traits(of: $1, in: family).weight - goal) } ?? face
    }

    /// The face of a family that is the leaning, or upright, `face`, keeping its weight.
    nonisolated static func face(_ face: String, of family: String, italic: Bool) -> String {
        let now = traits(of: face, in: family)
        guard now.italic != italic else { return face }
        let faces = self.faces(of: family).filter { traits(of: $0, in: family).italic == italic }
        return faces.min { abs(traits(of: $0, in: family).weight - now.weight) < abs(traits(of: $1, in: family).weight - now.weight) } ?? face
    }

    nonisolated static func isBold(_ face: String, of family: String) -> Bool { traits(of: face, in: family).weight >= 8 }
    nonisolated static func isItalic(_ face: String, of family: String) -> Bool { traits(of: face, in: family).italic }

    // MARK: Features and axes

    /// An OpenType feature a font has, by its tag, as the font names it.
    nonisolated struct Feature: Hashable {
        let tag: String
        let name: String
    }

    private nonisolated static let featureCache = Shared([String: [Feature]]())

    /// The OpenType features a font has that can be turned on, in the order it lists them.
    nonisolated static func features(of font: NSFont) -> [Feature] {
        if let known = featureCache.with({ $0[font.fontName] }) { return known }
        var out: [Feature] = []
        var seen = Set<String>()
        let types = (CTFontCopyFeatures(font) as? [[String: Any]]) ?? []
        for type in types {
            let typeName = type[kCTFontFeatureTypeNameKey as String] as? String
            for selector in type[kCTFontFeatureTypeSelectorsKey as String] as? [[String: Any]] ?? [] {
                guard let tag = selector[kCTFontOpenTypeFeatureTag as String] as? String,
                      (selector[kCTFontOpenTypeFeatureValue as String] as? NSNumber)?.intValue ?? 1 != 0,
                      seen.insert(tag).inserted else { continue }
                var name = selector[kCTFontFeatureSelectorNameKey as String] as? String ?? tag
                // A character variant's "On" says nothing; its type is what it is called.
                if ["On", "Off"].contains(name), let typeName { name = typeName }
                out.append(Feature(tag: tag, name: name))
            }
        }
        featureCache.with {
            if $0.count > 500 { $0.removeAll() }
            $0[font.fontName] = out
        }
        return out
    }

    nonisolated static func tags(of font: NSFont) -> Set<String> { Set(features(of: font).map(\.tag)) }

    /// One axis a variable font can be set along.
    nonisolated struct Axis: Hashable {
        let tag: String
        let name: String
        let range: ClosedRange<Double>
        let standard: Double
    }

    /// The axes of a variable font that are meant to be set by hand; none for any other font.
    nonisolated static func axes(of font: NSFont) -> [Axis] {
        let all = (CTFontCopyVariationAxes(font) as? [[String: Any]]) ?? []
        return all.compactMap { a in
            guard (a[kCTFontVariationAxisHiddenKey as String] as? NSNumber)?.boolValue != true,
                  let id = (a[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.uint32Value,
                  let lo = (a[kCTFontVariationAxisMinimumValueKey as String] as? NSNumber)?.doubleValue,
                  let hi = (a[kCTFontVariationAxisMaximumValueKey as String] as? NSNumber)?.doubleValue, lo < hi else { return nil }
            let standard = (a[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber)?.doubleValue ?? lo
            let tag = Self.tag(id)
            return Axis(tag: tag, name: a[kCTFontVariationAxisNameKey as String] as? String ?? tag, range: lo...hi, standard: standard)
        }
    }

    /// A four-letter tag as the number fonts keep it, and back.
    nonisolated static func code(_ tag: String) -> UInt32 {
        tag.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    nonisolated static func tag(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? ""
    }
}

/// Lays text out the one way Bezzle does everywhere (on the canvas, in the editor, in exports),
/// so what you type is exactly what is drawn.
nonisolated enum TextLayout {
    /// The attributes of letters of a layer of `style` in `color`, looking as `look` says, and of
    /// a paragraph of its own.
    static func attributes(_ style: TextStyle, look: TextLook = .plain, color: RGBA) -> [NSAttributedString.Key: Any] {
        var attrs = letterAttributes(style, look: look, color: color, lift: lift(style))
        attrs[.paragraphStyle] = paragraph(style)
        attrs[.bezzleLook] = LookBox(look)
        return attrs
    }

    /// How far the letters are raised in their lines, when the lines are set further apart than
    /// the font's own: the extra room is shared above and below the letters, as the eye expects.
    /// The same for every letter of a text, so that letters of all sizes share a baseline.
    private static func lift(_ style: TextStyle) -> CGFloat {
        guard let spacing = style.lineSpacing, spacing > 0 else { return 0 }
        let font = Fonts.font(style)
        let natural = ceil(font.ascender - font.descender + font.leading)
        return (spacing - natural) / 2
    }

    private static func letterAttributes(_ style: TextStyle, look: TextLook, color: RGBA?, lift: CGFloat) -> [NSAttributedString.Key: Any] {
        let letters = look.resolved(over: style, color: color ?? .black)
        let font = Fonts.font(letters.style(over: style))
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color == nil ? NSColor.clear : letters.color.nsColor,
            .kern: letters.tracking / 1000 * letters.size,
        ]
        if lift != 0 { attrs[.baselineOffset] = lift }
        if letters.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if letters.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attrs
    }

    /// How a paragraph of the text is set: aligned, its lines as far apart as asked, with room after it.
    private static func paragraph(_ style: TextStyle) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch style.align {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justify: .justified
        }
        if let spacing = style.lineSpacing, spacing > 0 {
            paragraph.minimumLineHeight = spacing
            paragraph.maximumLineHeight = spacing
        }
        if let after = style.paragraphSpacing, after > 0 { paragraph.paragraphSpacing = after }
        return paragraph
    }

    /// Runs of words as an attributed string, each letter drawn as it looks, every one marked with
    /// its look (`.bezzleLook`), and each item of a list with its marker (`.bezzleMarker`). `color`
    /// nil draws them unseen, as a text whose colour is off. `cased` sets them in the letter case
    /// the style asks for; the editor shows them as typed.
    static func attributed(_ runs: [TextSpan], style: TextStyle, color: RGBA?, cased: Bool = true) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lift = lift(style)
        var texts = runs.map(\.text)
        if cased, let letterCase = style.letterCase, letterCase != .smallCaps {
            let whole = texts.joined()
            let set = letterCase.apply(whole)
            // Cased whole, so words are capitalised across runs, unless that changes how long it is.
            if set.utf16.count == whole.utf16.count {
                let ns = set as NSString
                var at = 0
                texts = texts.map { t in
                    let n = t.utf16.count
                    defer { at += n }
                    return ns.substring(with: NSRange(location: at, length: n))
                }
            } else {
                texts = texts.map(letterCase.apply)
            }
        }
        for (run, text) in zip(runs, texts) {
            var attrs = letterAttributes(style, look: run.look, color: color, lift: lift)
            attrs[.bezzleLook] = LookBox(run.look)
            if cased, style.letterCase == .smallCaps, let font = attrs[.font] as? NSFont, !Fonts.tags(of: font).contains("smcp") {
                appendSmallCaps(text, attrs, run.look.resolved(over: style, color: color ?? .black), style: style, to: out)
            } else {
                out.append(NSAttributedString(string: text, attributes: attrs))
            }
        }
        setParagraphs(out, style: style)
        return out
    }

    /// Small letters as capitals of their height, for a font that has no small capitals of its own.
    private static func appendSmallCaps(_ text: String, _ attrs: [NSAttributedString.Key: Any], _ letters: Letters, style: TextStyle, to out: NSMutableAttributedString) {
        var small = letters
        small.size = (letters.size * 0.76 * 10).rounded() / 10
        var smallAttrs = attrs
        smallAttrs[.font] = Fonts.font(small.style(over: style))
        smallAttrs[.kern] = (letters.tracking / 1000 + 0.03) * small.size
        var rest = Substring(text)
        while let first = rest.first {
            let lower = first.isLowercase
            let end = rest.firstIndex { $0.isLowercase != lower } ?? rest.endIndex
            let piece = String(rest[..<end])
            out.append(NSAttributedString(string: lower ? piece.uppercased() : piece, attributes: lower ? smallAttrs : attrs))
            rest = rest[end...]
        }
    }

    /// Sets each paragraph: its alignment and spacing, and for an item of a list, its marker and
    /// how far in its words begin, the same for every item of a list so their words line up.
    private static func setParagraphs(_ s: NSMutableAttributedString, style: TextStyle) {
        guard s.length > 0 else { return }
        let whole = NSRange(location: 0, length: s.length)
        let plain = paragraph(style)
        s.addAttribute(.paragraphStyle, value: plain, range: whole)
        let ns = s.string as NSString
        var paragraphs: [(range: NSRange, list: TextList?)] = []
        var at = 0
        while at < s.length {
            let r = ns.paragraphRange(for: NSRange(location: at, length: 0))
            paragraphs.append((r, (s.attribute(.bezzleLook, at: r.location, effectiveRange: nil) as? LookBox)?.look.list))
            at = NSMaxRange(r)
        }
        var i = 0
        while i < paragraphs.count {
            guard paragraphs[i].list != nil else { i += 1; continue }
            var j = i
            while j < paragraphs.count, paragraphs[j].list != nil { j += 1 }
            // One list: its markers, counted on through its numbered items.
            var number = 0
            var markers: [(text: String, font: NSFont)] = []
            for k in i..<j {
                let font = s.attribute(.font, at: paragraphs[k].range.location, effectiveRange: nil) as? NSFont ?? Fonts.font(style)
                if paragraphs[k].list == .number {
                    number += 1
                    markers.append(("\(number).", font))
                } else {
                    number = 0
                    markers.append(("•", font))
                }
            }
            let size = markers.map(\.font.pointSize).max() ?? style.size
            let column = max(markers.map { width(of: $0.text, in: $0.font) }.max() ?? 0, size * 0.6)
            let gap = (size * 0.5).rounded()
            let item = plain.mutableCopy() as! NSMutableParagraphStyle
            item.headIndent = ceil(column + gap)
            item.firstLineHeadIndent = item.headIndent
            for k in i..<j {
                s.addAttribute(.paragraphStyle, value: item, range: paragraphs[k].range)
                s.addAttribute(.bezzleMarker, value: ListMarker(markers[k - i].text, gap: gap), range: paragraphs[k].range)
            }
            i = j
        }
    }

    static func width(of text: String, in font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// A list item's marker as it is placed: its baseline's left end, in the text's own space.
    struct Marker {
        let text: String
        let font: NSFont
        let color: NSColor
        let at: CGPoint
        /// Whether its letters have a colour of their own, rather than the text's.
        var own = false
    }

    /// The markers of the list items whose first letters are among `characters`, or all of them.
    static func markers(_ manager: NSLayoutManager, characters: NSRange? = nil) -> [Marker] {
        guard let storage = manager.textStorage, storage.length > 0 else { return [] }
        let ns = storage.string as NSString
        let range = characters.map { NSIntersectionRange($0, NSRange(location: 0, length: storage.length)) } ?? NSRange(location: 0, length: storage.length)
        var out: [Marker] = []
        storage.enumerateAttribute(.bezzleMarker, in: range) { value, r, _ in
            guard let marker = value as? ListMarker else { return }
            var at = r.location
            while at < NSMaxRange(r) {
                let paragraph = ns.paragraphRange(for: NSRange(location: at, length: 0))
                if paragraph.location == at {
                    let glyph = manager.glyphIndexForCharacter(at: at)
                    let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let place = manager.location(forGlyphAt: glyph)
                    let font = storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont ?? NSFont.systemFont(ofSize: 12)
                    let color = storage.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor ?? .black
                    let lift = storage.attribute(.baselineOffset, at: at, effectiveRange: nil) as? CGFloat ?? 0
                    let x = fragment.minX + place.x - marker.gap - width(of: marker.text, in: font)
                    out.append(Marker(text: marker.text, font: font, color: color, at: CGPoint(x: x, y: fragment.minY + place.y - lift),
                                      own: Manager.ownColor(storage.attribute(.bezzleLook, at: at, effectiveRange: nil))))
                }
                at = NSMaxRange(paragraph)
            }
        }
        return out
    }

    /// Draws text as a layout manager does, and the markers of its list items with it.
    final class Manager: NSLayoutManager {
        /// An item of a list on the empty line at the end, which has no letters to carry it, as
        /// the editor has one while it is typed.
        struct Trailing: Equatable {
            let text: String
            let gap: CGFloat
            let font: NSFont
            let color: NSColor
            let indent: CGFloat
            let lift: CGFloat
        }

        var trailing: Trailing?

        /// What the letters of the text's own colour are painted with, when that is a gradient or
        /// a picture: it paints the space the text is drawn in, and shows through those letters
        /// alone, their lines under and through them and their list markers. Letters of a colour
        /// of their own are drawn in it, as they are.
        var painting: ((CGContext) -> Void)?

        /// Which letters are being drawn while some are painted.
        private enum Part { case own, painted }
        private var drawing: Part?
        /// Into a PDF, the outlines of the letters to paint, gathered rather than drawn, in the
        /// space the drawing began in.
        private var outlines: (path: CGMutablePath, space: CGAffineTransform)?

        override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
            guard let painting, let ctx = NSGraphicsContext.current?.cgContext else {
                super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
                drawMarkers(forGlyphRange: glyphsToShow, at: origin)
                return
            }
            drawing = .own
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            drawMarkers(forGlyphRange: glyphsToShow, at: origin)
            drawing = .painted
            ctx.saveGState()
            defer {
                ctx.restoreGState()
                drawing = nil
                outlines = nil
            }
            if ctx.width == 0 {
                // A PDF cannot keep only what lies on what was drawn before, so the paint is cut
                // to the letters' outlines, which keeps them sharp. Lines under and through them
                // keep the text's colour.
                let path = CGMutablePath()
                outlines = (path, ctx.ctm)
                super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
                drawMarkers(forGlyphRange: glyphsToShow, at: origin)
                outlines = nil
                guard !path.isEmpty else { return }
                ctx.addPath(path)
                ctx.clip()
                painting(ctx)
            } else {
                // The letters, and the paint over them, keeping only what lies on them: drawn
                // whole in a layer of its own first, so that where it leaves nothing, the
                // letters go too.
                let used = boundingRect(forGlyphRange: glyphsToShow, in: textContainers[0]).offsetBy(dx: origin.x, dy: origin.y)
                let room = used.insetBy(dx: -max(used.height, 24), dy: -max(used.height, 24))
                ctx.beginTransparencyLayer(in: room, auxiliaryInfo: nil)
                super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
                drawMarkers(forGlyphRange: glyphsToShow, at: origin)
                ctx.setBlendMode(.sourceIn)
                ctx.beginTransparencyLayer(in: room, auxiliaryInfo: nil)
                ctx.saveGState()
                painting(ctx)
                ctx.restoreGState()
                ctx.endTransparencyLayer()
                ctx.endTransparencyLayer()
            }
        }

        override func showCGGlyphs(_ glyphs: UnsafePointer<CGGlyph>, positions: UnsafePointer<CGPoint>, count: Int, font: NSFont,
                                   textMatrix: CGAffineTransform, attributes: [NSAttributedString.Key: Any] = [:], in ctx: CGContext) {
            if let drawing, drawing != (Self.ownColor(attributes[.bezzleLook]) ? .own : .painted) { return }
            guard let outlines else {
                super.showCGGlyphs(glyphs, positions: positions, count: count, font: font, textMatrix: textMatrix, attributes: attributes, in: ctx)
                return
            }
            let toSpace = ctx.ctm.concatenating(outlines.space.inverted())
            for i in 0..<count {
                var place = CGAffineTransform(a: textMatrix.a, b: textMatrix.b, c: textMatrix.c, d: textMatrix.d,
                                              tx: positions[i].x, ty: positions[i].y).concatenating(toSpace)
                if let glyph = CTFontCreatePathForGlyph(font, glyphs[i], &place) { outlines.path.addPath(glyph) }
            }
        }

        override func drawUnderline(forGlyphRange glyphRange: NSRange, underlineType: NSUnderlineStyle, baselineOffset: CGFloat,
                                    lineFragmentRect: NSRect, lineFragmentGlyphRange: NSRange, containerOrigin: NSPoint) {
            guard drawn(glyphRange) else { return }
            super.drawUnderline(forGlyphRange: glyphRange, underlineType: underlineType, baselineOffset: baselineOffset,
                                lineFragmentRect: lineFragmentRect, lineFragmentGlyphRange: lineFragmentGlyphRange, containerOrigin: containerOrigin)
        }

        override func drawStrikethrough(forGlyphRange glyphRange: NSRange, strikethroughType: NSUnderlineStyle, baselineOffset: CGFloat,
                                        lineFragmentRect: NSRect, lineFragmentGlyphRange: NSRange, containerOrigin: NSPoint) {
            guard drawn(glyphRange) else { return }
            super.drawStrikethrough(forGlyphRange: glyphRange, strikethroughType: strikethroughType, baselineOffset: baselineOffset,
                                    lineFragmentRect: lineFragmentRect, lineFragmentGlyphRange: lineFragmentGlyphRange, containerOrigin: containerOrigin)
        }

        /// Whether the letters of `glyphs` are among those being drawn now.
        private func drawn(_ glyphs: NSRange) -> Bool {
            guard let drawing, let storage = textStorage, storage.length > 0 else { return true }
            let at = min(characterIndexForGlyph(at: glyphs.location), storage.length - 1)
            return drawing == (Self.ownColor(storage.attribute(.bezzleLook, at: at, effectiveRange: nil)) ? .own : .painted)
        }

        /// Whether letters of this look have a colour of their own, rather than the text's.
        static func ownColor(_ look: Any?) -> Bool { (look as? LookBox)?.look.color != nil }

        /// The markers of the list items among `glyphs`, those being drawn now.
        private func drawMarkers(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            var markers = TextLayout.markers(self, characters: characters)
            if let t = trailing, !extraLineFragmentRect.isEmpty {
                let rect = extraLineFragmentRect
                let baseline = rect.maxY - (defaultLineHeight(for: t.font) - defaultBaselineOffset(for: t.font)) - t.lift
                markers.append(Marker(text: t.text, font: t.font, color: t.color,
                                      at: CGPoint(x: rect.minX + t.indent - t.gap - TextLayout.width(of: t.text, in: t.font), y: baseline)))
            }
            for marker in markers where drawing.map({ $0 == (marker.own ? .own : .painted) }) ?? true {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: marker.text, attributes: [
                    .font: marker.font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                ]))
                let at = CGPoint(x: origin.x + marker.at.x, y: origin.y + marker.at.y)
                if let outlines {
                    TextLayout.addOutlines(of: line, at: at, to: outlines.path, transform: ctx.ctm.concatenating(outlines.space.inverted()))
                    continue
                }
                ctx.saveGState()
                ctx.setFillColor(marker.color.cgColor)
                // The context's y runs down, as the text's does.
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                ctx.textPosition = at
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
        }
    }

    /// The outlines of a line's letters as it is drawn with its baseline's left end at `at`, in a
    /// space whose y runs down, carried by `transform`.
    static func addOutlines(of line: CTLine, at: CGPoint, to path: CGMutablePath, transform: CGAffineTransform) {
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0, let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for i in 0..<count {
                var place = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: at.x + positions[i].x, ty: at.y - positions[i].y).concatenating(transform)
                if let glyph = CTFontCreatePathForGlyph(font as! CTFont, glyphs[i], &place) { path.addPath(glyph) }
            }
        }
    }

    final class Laid {
        let storage: NSTextStorage
        let manager = Manager()
        let container: NSTextContainer
        /// An empty text has no letters to carry its font, so it is kept here for the height of its one line.
        let font: NSFont

        init(_ text: NSAttributedString, font: NSFont, width: CGFloat) {
            self.font = font
            storage = NSTextStorage(attributedString: text)
            container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.usesFontLeading = true
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
        }

        var usedSize: CGSize {
            let used = manager.usedRect(for: container)
            // An empty text still has the height of a line.
            let height = storage.length == 0 ? manager.defaultLineHeight(for: font) : used.height
            return CGSize(width: used.width, height: height)
        }

        /// Draws with the text's top left at `origin`, in a flipped graphics context: the letters
        /// of the text's own colour painted by `painting`, when they are painted with a gradient
        /// or a picture. See `Manager.painting`.
        func draw(at origin: CGPoint, painting: ((CGContext) -> Void)? = nil) {
            let range = manager.glyphRange(for: container)
            manager.painting = painting
            defer { manager.painting = nil }
            manager.drawBackground(forGlyphRange: range, at: origin)
            manager.drawGlyphs(forGlyphRange: range, at: origin)
        }
    }

    /// What a layout depends on. A large design has thousands of texts, so the layouts are kept
    /// in plenty, and found without building strings.
    private struct Key: Hashable {
        let text: String
        let spans: [TextSpan]?
        let style: TextStyle
        /// The colour of the letters without one of their own.
        let color: RGBA?
        /// The width laid out at; none for a text's natural width.
        let width: CGFloat?
    }

    /// The layouts kept for one thread. Text Kit's layouts are each for one thread at a time, and
    /// tiles are drawn on several at once, so each thread keeps its own: the main thread plenty,
    /// for it lays out every text it shows, the others what the tiles they draw show.
    private final class Layouts {
        var cache: [Key: Laid] = [:]
        let kept: Int
        init(kept: Int) { self.kept = kept }
    }

    private nonisolated(unsafe) static let onMain = Layouts(kept: 12_000)

    private static var layouts: Layouts {
        if Thread.isMainThread { return onMain }
        let threads = Thread.current.threadDictionary
        if let mine = threads["Bezzle text layouts"] as? Layouts { return mine }
        let mine = Layouts(kept: 1_000)
        threads["Bezzle text layouts"] = mine
        return mine
    }

    static func attributed(_ node: Node) -> NSAttributedString {
        attributed(node.runs, style: node.style ?? TextStyle(), color: node.letterColor)
    }

    private static func laid(_ node: Node, width: CGFloat) -> Laid {
        let style = node.style ?? TextStyle()
        return Laid(attributed(node), font: Fonts.font(style), width: width)
    }

    /// How tall the text is wrapped to `width`, worked out afresh and not kept: for trying sizes
    /// without crowding out the layouts the canvas draws.
    static func height(_ node: Node, width: CGFloat) -> CGFloat {
        ceil(laid(node, width: max(width, 1)).usedSize.height)
    }

    /// The text laid out at the width it is drawn at.
    static func layout(_ node: Node) -> Laid {
        let style = node.style ?? TextStyle()
        let width = style.sizing == .autoWidth ? naturalWidth(node) + 0.5 : max(node.frame.width, 1)
        let key = Key(text: node.text ?? "", spans: node.spans, style: style, color: node.letterColor, width: width)
        let kept = layouts
        if let laid = kept.cache[key] { return laid }
        let laid = laid(node, width: width)
        if kept.cache.count > kept.kept { kept.cache.removeAll() }
        kept.cache[key] = laid
        return laid
    }

    /// How wide the longest line is with all the room it wants.
    static func naturalWidth(_ node: Node) -> CGFloat {
        var style = node.style ?? TextStyle()
        style.align = .left
        var probe = node
        probe.style = style
        let key = Key(text: node.text ?? "", spans: node.spans, style: style, color: nil, width: nil)
        let kept = layouts
        if let laid = kept.cache[key] { return ceil(laid.usedSize.width) }
        let laid = laid(probe, width: 100_000)
        kept.cache[key] = laid
        return ceil(laid.usedSize.width)
    }

    /// How far down a text's lines begin in its frame: below its top for a box of fixed size whose
    /// lines lie in its middle or at its bottom, and above it when they are more than fit.
    static func offset(_ node: Node) -> CGFloat {
        guard let style = node.style, style.sizing == .fixed, let vertical = style.vertical, vertical != .top else { return 0 }
        let room = node.frame.height - layout(node).usedSize.height
        return vertical == .middle ? (room / 2).rounded() : room.rounded()
    }

    /// How far below a text layer's top its first line's baseline is.
    static func firstBaseline(_ node: Node) -> CGFloat {
        let laid = layout(node)
        guard laid.storage.length > 0 else { return Fonts.font(node.style ?? TextStyle()).ascender + offset(node) }
        let fragment = laid.manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        return fragment.minY + laid.manager.location(forGlyphAt: 0).y + offset(node)
    }

    /// The frame a text layer takes for its words, keeping its top left where it is.
    static func fittedFrame(_ node: Node) -> CGRect {
        guard node.kind == .text else { return node.frame }
        let style = node.style ?? TextStyle()
        var frame = node.frame
        if style.sizing == .autoWidth {
            frame.size.width = max(naturalWidth(node), 1)
        }
        // A box of fixed size keeps its height, whatever its words take.
        if style.sizing != .fixed {
            frame.size.height = ceil(layout(Node.with(node, frame: frame)).usedSize.height)
        }
        return frame
    }
}

extension Node {
    /// The colour a text's letters without one of their own are drawn in: its fill's, or none.
    /// Painted with a gradient or a picture, they are drawn solid, to be painted through.
    nonisolated var letterColor: RGBA? {
        guard fill.on else { return nil }
        return fill.paints ? fill.color.with(alpha: 1) : fill.color
    }

    nonisolated static func with(_ node: Node, frame: CGRect) -> Node {
        var n = node
        n.frame = frame
        return n
    }

    /// For text layers dragged by a corner: a box of fixed `size`, and the letters and lines of
    /// `style` as big as they can be, to a tenth of a point, with the words wrapped inside it.
    /// Letters of sizes of their own grow and shrink with them.
    mutating func fit(_ style: TextStyle, into size: CGSize) {
        guard kind == .text, style.size > 0 else { return }
        var base = style
        base.sizing = .fixed
        let width = max(size.width, 1)
        frame.size = CGSize(width: width, height: max(size.height, 1))
        let letters = spans
        func sized(_ tenths: Int) -> Node {
            var n = self
            let k = CGFloat(tenths) / (base.size * 10)
            n.style = base.scaled(by: k)
            n.spans = letters
            n.scaleLetters(by: k)
            return n
        }
        func fits(_ tenths: Int) -> Bool {
            TextLayout.height(sized(tenths), width: width) <= size.height + 0.5
        }
        // From the size it was, doubled or halved until past the fit, then halved in between.
        var lo = max(Int((base.size * 10).rounded()), 10), hi = lo
        if fits(lo) {
            repeat { lo = hi; hi *= 2 } while hi < 100_000 && fits(hi)
        } else {
            repeat { hi = lo; lo = max(lo / 2, 10) } while lo > 10 && !fits(lo)
        }
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if fits(mid) { lo = mid } else { hi = mid }
        }
        let best = sized(lo)
        self.style = best.style
        spans = best.spans
        refit()
    }

    /// For text layers, a size typed in: a new width alone wraps the words to it, and text of auto
    /// size takes a fixed width; a new height, or both, grows or shrinks the letters and lines, and
    /// a fixed width or size with them, so the words wrap where they did.
    mutating func resizeText(to size: CGSize, byHeight: Bool) {
        let old = frame
        guard kind == .text, old.width > 0, old.height > 0, size != old.size else { return }
        if !byHeight, size.height == old.height {
            if style?.sizing == .autoWidth { style?.sizing = .autoHeight }
            frame.size.width = size.width
        } else {
            let k = byHeight ? size.height / old.height : size.width / old.width
            scaleType(by: k)
            switch style?.sizing {
            case .autoHeight: frame.size.width = (old.width * k).rounded()
            case .fixed: frame.size = CGSize(width: (old.width * k).rounded(), height: (old.height * k).rounded())
            default: break
            }
        }
        refit()
    }

    /// For text layers: the frame refitted to the words after a change.
    mutating func refit() {
        guard kind == .text else { return }
        // Along a curve, its frame is the box round its letters there.
        if curve != nil {
            refitCurve()
            return
        }
        let old = frame
        let fitted = TextLayout.fittedFrame(self)
        // Centred and right-aligned text grows around its anchor rather than to the right.
        if style?.sizing == .autoWidth {
            switch style?.align ?? .left {
            case .left, .justify: frame = fitted
            case .center: frame = CGRect(x: old.midX - fitted.width / 2, y: old.minY, width: fitted.width, height: fitted.height)
            case .right: frame = CGRect(x: old.maxX - fitted.width, y: old.minY, width: fitted.width, height: fitted.height)
            }
        } else {
            frame = fitted
        }
    }
}
