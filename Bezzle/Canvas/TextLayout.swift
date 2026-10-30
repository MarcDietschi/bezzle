import AppKit

/// Fonts by family and face, as the Font Book names them, with the Mac's own font as "System".
enum Fonts {
    nonisolated static let systemFaces: [(String, NSFont.Weight)] = [
        ("Ultralight", .ultraLight), ("Thin", .thin), ("Light", .light), ("Regular", .regular),
        ("Medium", .medium), ("Semibold", .semibold), ("Bold", .bold), ("Heavy", .heavy), ("Black", .black),
    ]

    static let families: [String] = [TextStyle.system] + NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }

    static func faces(of family: String) -> [String] {
        if family == TextStyle.system {
            return systemFaces.flatMap { [$0.0, "\($0.0) Italic"] }
        }
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
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

    private nonisolated struct FontKey: Hashable { let family: String, face: String, size: CGFloat }
    /// Asked for by text drawn on several threads at once.
    private nonisolated static let cache = Shared([FontKey: NSFont]())
    /// The font manager is asked one at a time.
    private nonisolated static let resolving = NSLock()

    nonisolated static func font(_ style: TextStyle) -> NSFont {
        let key = FontKey(family: style.family, face: style.face, size: style.size)
        if let font = cache.with({ $0[key] }) { return font }
        let font = resolving.withLock { resolve(style) }
        cache.with {
            if $0.count > 2000 { $0.removeAll() }
            $0[key] = font
        }
        return font
    }

    private nonisolated static func resolve(_ style: TextStyle) -> NSFont {
        let size = max(style.size, 1)
        if style.family == TextStyle.system {
            let italic = style.face.hasSuffix("Italic")
            let name = italic ? String(style.face.dropLast(" Italic".count)) : style.face
            let weight = systemFaces.first { $0.0 == name }?.1 ?? .regular
            let font = NSFont.systemFont(ofSize: size, weight: weight)
            guard italic else { return font }
            return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? font
        }
        let members = NSFontManager.shared.availableMembers(ofFontFamily: style.family) ?? []
        let member = members.first { ($0.count > 1 ? $0[1] as? String : nil) == style.face } ?? members.first
        if let name = member?.first as? String, let font = NSFont(name: name, size: size) { return font }
        return NSFont(name: style.family, size: size) ?? NSFont.systemFont(ofSize: size)
    }
}

/// Lays text out the one way Bezzle does everywhere (on the canvas, in the editor, in exports),
/// so what you type is exactly what is drawn.
nonisolated enum TextLayout {
    static func attributes(_ style: TextStyle, color: RGBA) -> [NSAttributedString.Key: Any] {
        let font = Fonts.font(style)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch style.align {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color.nsColor,
            .kern: style.tracking / 1000 * style.size,
        ]
        if let spacing = style.lineSpacing, spacing > 0 {
            paragraph.minimumLineHeight = spacing
            paragraph.maximumLineHeight = spacing
            // The extra room is shared above and below the letters, as the eye expects.
            let natural = ceil(font.ascender - font.descender + font.leading)
            attrs[.baselineOffset] = (spacing - natural) / 2
        }
        if style.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attrs[.paragraphStyle] = paragraph
        return attrs
    }

    final class Laid {
        let storage: NSTextStorage
        let manager = NSLayoutManager()
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

        /// Draws with the text's top left at `origin`, in a flipped graphics context.
        func draw(at origin: CGPoint) {
            let range = manager.glyphRange(for: container)
            manager.drawBackground(forGlyphRange: range, at: origin)
            manager.drawGlyphs(forGlyphRange: range, at: origin)
        }
    }

    /// What a layout depends on. A large design has thousands of texts, so the layouts are kept
    /// in plenty, and found without building strings.
    private struct Key: Hashable {
        let text: String
        let style: TextStyle
        let fill: Fill?
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
        let style = node.style ?? TextStyle()
        let attrs = attributes(style, color: node.fill.on ? node.fill.color : RGBA(r: 0, g: 0, b: 0, a: 0))
        let text = node.text ?? ""
        return NSAttributedString(string: style.letterCase?.apply(text) ?? text, attributes: attrs)
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
        let key = Key(text: node.text ?? "", style: style, fill: node.fill, width: width)
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
        let key = Key(text: node.text ?? "", style: style, fill: nil, width: nil)
        let kept = layouts
        if let laid = kept.cache[key] { return ceil(laid.usedSize.width) }
        let laid = laid(probe, width: 100_000)
        kept.cache[key] = laid
        return ceil(laid.usedSize.width)
    }

    /// How far below a text layer's top its first line's baseline is.
    static func firstBaseline(_ node: Node) -> CGFloat {
        let laid = layout(node)
        guard laid.storage.length > 0 else { return Fonts.font(node.style ?? TextStyle()).ascender }
        let fragment = laid.manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        return fragment.minY + laid.manager.location(forGlyphAt: 0).y
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
    nonisolated static func with(_ node: Node, frame: CGRect) -> Node {
        var n = node
        n.frame = frame
        return n
    }

    /// For text layers dragged by a corner: a box of fixed `size`, and the letters and lines of
    /// `style` as big as they can be, to a tenth of a point, with the words wrapped inside it.
    mutating func fit(_ style: TextStyle, into size: CGSize) {
        guard kind == .text, style.size > 0 else { return }
        var base = style
        base.sizing = .fixed
        let width = max(size.width, 1)
        frame.size = CGSize(width: width, height: max(size.height, 1))
        func styled(_ tenths: Int) -> TextStyle { base.scaled(by: CGFloat(tenths) / (base.size * 10)) }
        func fits(_ tenths: Int) -> Bool {
            var n = self
            n.style = styled(tenths)
            return TextLayout.height(n, width: width) <= size.height + 0.5
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
        self.style = styled(lo)
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
            style = style?.scaled(by: k)
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
        let old = frame
        let fitted = TextLayout.fittedFrame(self)
        // Centred and right-aligned text grows around its anchor rather than to the right.
        if style?.sizing == .autoWidth {
            switch style?.align ?? .left {
            case .left: frame = fitted
            case .center: frame = CGRect(x: old.midX - fitted.width / 2, y: old.minY, width: fitted.width, height: fitted.height)
            case .right: frame = CGRect(x: old.maxX - fitted.width, y: old.minY, width: fitted.width, height: fitted.height)
            }
        } else {
            frame = fitted
        }
    }
}
