import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The panel on the right while the design is inspected: what someone building it needs, each
/// value copied with a click. With a layer picked: where it lies, drawn as a box inside the one
/// round it; its looks and type by the names the design gives them; the layer as code; and the
/// layer itself to drag out as a file. With nothing picked: the design's colours and type, its
/// tokens and the way to hand it all to Claude, and what is marked for export.
struct InspectInspector: View {
    let store: DocumentStore
    @AppStorage("inspect.platform") private var platformName = Inspect.Platform.css.rawValue

    var body: some View {
        let platform = Inspect.Platform(rawValue: platformName) ?? .css
        let seen = store.seenDoc
        let tokens = Inspect.Tokens(seen)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if store.selection.count == 1, let id = store.selection.first, let node = seen.node(id) {
                    LayerPath(store: store, node: node)
                    BoxCard(store: store, node: node)
                    if node.kind == .text { TypeCard(node: node, tokens: tokens, platform: platform) }
                    LookCard(node: node, tokens: tokens, platform: platform)
                    if node.isArtboard, let grid = node.layout, !grid.isEmpty { GridSpecCard(grid: grid, board: node) }
                    CodeCard(node: node, doc: seen, tokens: tokens, platformName: $platformName)
                    AssetCard(store: store, node: node)
                } else {
                    PaletteCard(store: store, tokens: tokens, platform: platform)
                    TypeSamplesCard(store: store, tokens: tokens, platform: platform)
                    HandOffCard(store: store)
                    MarkedAssetsCard(store: store)
                }
            }
            .padding(.horizontal, Inspector.gutter)
            .padding(.top, 14)
            .padding(.bottom, 28)
            .animation(Theme.spring, value: store.selection)
        }
        .scrollIndicators(.never)
        .edgeFade(length: 20)
    }
}

// MARK: - Values to copy

/// A value as it reads, copied with a click: it lights up while pointed at and ticks once copied.
struct CopyValue: View {
    let text: String
    /// What is copied, where it differs from what shows.
    var copy: String?
    var color: Color = Theme.ink
    var size: CGFloat = 12
    var weight: Font.Weight = .medium
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 3) {
            Text(verbatim: text)
                .font(.system(size: size, weight: weight).monospacedDigit())
                .foregroundStyle(copied ? Theme.pencil : color)
                .lineLimit(1)
                .truncationMode(.middle)
            if copied {
                CheckMark(size: 8, color: Theme.pencil)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering ? Theme.pencilWash : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            InspectCopy.put(copy ?? text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        }
        .help(Text(verbatim: copy ?? text))
        .animation(Theme.quick, value: hovering)
        .animation(Theme.pop, value: copied)
        .accessibilityAddTraits(.isButton)
    }
}

/// The name a look is given in the design, as a small tag that copies what code calls it.
private struct TokenTag: View {
    let token: Inspect.Token
    let platform: Inspect.Platform
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 3) {
            if copied {
                CheckMark(size: 8, color: Theme.pencil)
                    .transition(.scale.combined(with: .opacity))
            }
            Text(verbatim: token.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Theme.pencil)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Capsule().fill(Theme.pencilWash.opacity(hovering ? 1.6 : 1)))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onTapGesture {
            InspectCopy.put(token.code(platform))
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        }
        .help(Text(verbatim: token.code(platform)))
        .animation(Theme.quick, value: hovering)
        .animation(Theme.pop, value: copied)
    }
}

/// A row of a spec: what it is, quietly, and its values.
private struct SpecRow<Content: View>: View {
    let label: LocalizedStringResource
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink3)
                .lineLimit(1)
                .frame(width: 76, alignment: .leading)
            HStack(spacing: 4) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 22)
    }
}

/// A colour: its swatch, its value to copy, and its name in the design.
private struct ColourValue: View {
    let color: RGBA
    let token: Inspect.Token?
    let platform: Inspect.Platform

    var body: some View {
        Swatch(color: color, radius: 4)
            .frame(width: 16, height: 16)
        CopyValue(text: Inspect.hex(color), copy: platform == .css ? Inspect.hex(color) : Inspect.swiftColor(color))
        if let token { TokenTag(token: token, platform: platform) }
    }
}

private func number(_ v: CGFloat) -> String { CanvasView.number(v) }

// MARK: - Where it lies

/// The screen and groups the picked layer lies in, each picking that, and the layer's own name;
/// with the component it is a copy of, or lies in, and the variant shown.
private struct LayerPath: View {
    let store: DocumentStore
    let node: Node

    var body: some View {
        let seen = store.seenDoc
        let path = Inspect.path(of: node.id, in: seen)
        let above = Array(path.dropLast().suffix(3))
        VStack(alignment: .leading, spacing: 5) {
            if !above.isEmpty {
                HStack(spacing: 3) {
                    if path.count - 1 > above.count {
                        Text(verbatim: "…").foregroundStyle(Theme.ink3)
                    }
                    ForEach(above, id: \.id) { n in
                        Crumb(name: n.name) { store.selection = [n.id] }
                        Text(verbatim: "›")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.ink4)
                    }
                }
                .font(.system(size: 11.5))
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: node.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: node.isCopy ? String(localized: "Component") : node.kind.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
            }
            if let c = Inspect.component(of: node.id, in: seen) {
                HStack(spacing: 5) {
                    Image(systemName: "diamond")
                        .font(.system(size: 9, weight: .semibold))
                    Text(verbatim: c.master.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    Text(verbatim: c.variant)
                        .font(.system(size: 11.5))
                        .opacity(0.75)
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.linked)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Capsule().fill(Theme.linkedWash))
                .onTapGesture { if c.copy.id != node.id { store.selection = [c.copy.id] } }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }
}

private struct Crumb: View {
    let name: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(verbatim: name)
            .foregroundStyle(hovering ? Theme.pencil : Theme.ink2)
            .lineLimit(1)
            .truncationMode(.tail)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .animation(Theme.quick, value: hovering)
    }
}

/// Where the layer lies: drawn as a box inside the one it lies in, its width and height in the
/// middle and the four distances round it, as the canvas measures them; and where it is on its screen.
private struct BoxCard: View {
    let store: DocumentStore
    let node: Node

    var body: some View {
        let seen = store.seenDoc
        let box = Inspect.box(of: node.id, in: seen) ?? node.frame
        let size = node.isArtboard || node.rotation == 0 ? box.size : node.frame.size
        let parent = node.isArtboard ? nil : seen.parent(of: node.id)
        let insets = parent.flatMap { Inspect.box(of: $0.id, in: seen) }.map { Inspect.Insets(of: box, in: $0) }
        let screen = node.isArtboard ? nil : seen.artboard(of: node.id)
        VStack(alignment: .leading, spacing: 10) {
            BoxModel(name: parent?.name, size: size, insets: insets)
            if let screen {
                HStack(spacing: 10) {
                    pair("X", box.minX - screen.frame.minX)
                    pair("Y", box.minY - screen.frame.minY)
                    Spacer(minLength: 0)
                    if abs(node.rotation) > 0.01 {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.ink3)
                            CopyValue(text: "\(CanvasView.number(CGFloat(node.rotation)))°", copy: CanvasView.number(CGFloat(node.rotation)))
                        }
                    }
                }
            }
        }
        .padding(12)
        .card(radius: 12)
    }

    private func pair(_ label: String, _ value: CGFloat) -> some View {
        HStack(spacing: 2) {
            Text(verbatim: label)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink3)
            CopyValue(text: number(value))
        }
    }
}

/// A box inside the one round it, as a browser's tools draw one: the layer in pencil with its size,
/// and the room on each side in the canvas's pink, each number copied with a click.
private struct BoxModel: View {
    let name: String?
    let size: CGSize
    let insets: Inspect.Insets?

    var body: some View {
        let gap = Color(nsColor: CanvasInk.gap)
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let inner = insets == nil ? CGRect(x: 0, y: 0, width: w, height: h)
                : CGRect(x: w / 2 - 58, y: h / 2 - 22, width: 116, height: 44)
            ZStack(alignment: .topLeading) {
                if let insets {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Theme.ink4, style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
                    if let name {
                        Text(verbatim: name)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.ink3)
                            .lineLimit(1)
                            .frame(maxWidth: w / 2 - 20, alignment: .leading)
                            .offset(x: 9, y: 7)
                    }
                    // The lines across each side's room, with a tick at each end.
                    Canvas { ctx, _ in
                        var p = Path()
                        let lines: [(CGPoint, CGPoint)] = [
                            (CGPoint(x: inner.midX, y: 0), CGPoint(x: inner.midX, y: inner.minY)),
                            (CGPoint(x: inner.midX, y: inner.maxY), CGPoint(x: inner.midX, y: h)),
                            (CGPoint(x: 0, y: inner.midY), CGPoint(x: inner.minX, y: inner.midY)),
                            (CGPoint(x: inner.maxX, y: inner.midY), CGPoint(x: w, y: inner.midY)),
                        ]
                        for (a, b) in lines {
                            p.move(to: a)
                            p.addLine(to: b)
                            let across = a.y == b.y
                            for end in [a, b] {
                                p.move(to: across ? CGPoint(x: end.x, y: end.y - 3) : CGPoint(x: end.x - 3, y: end.y))
                                p.addLine(to: across ? CGPoint(x: end.x, y: end.y + 3) : CGPoint(x: end.x + 3, y: end.y))
                            }
                        }
                        ctx.stroke(p, with: .color(gap.opacity(0.7)), lineWidth: 1)
                    }
                    .allowsHitTesting(false)
                    side(insets.top, gap).position(x: inner.midX, y: inner.minY / 2)
                    side(insets.bottom, gap).position(x: inner.midX, y: (inner.maxY + h) / 2)
                    side(insets.left, gap).position(x: inner.minX / 2, y: inner.midY)
                    side(insets.right, gap).position(x: (inner.maxX + w) / 2, y: inner.midY)
                }
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.pencilWash)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.pencil, lineWidth: 1.2))
                    .frame(width: inner.width, height: inner.height)
                    .offset(x: inner.minX, y: inner.minY)
                HStack(spacing: 0) {
                    CopyValue(text: number(size.width), color: Theme.pencil, size: 12.5, weight: .semibold)
                    Text(verbatim: "×")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.pencil.opacity(0.7))
                    CopyValue(text: number(size.height), color: Theme.pencil, size: 12.5, weight: .semibold)
                }
                .position(x: inner.midX, y: inner.midY)
            }
        }
        .frame(height: insets == nil ? 56 : 136)
    }

    private func side(_ v: CGFloat, _ gap: Color) -> some View {
        CopyValue(text: number(v), color: v < -0.05 ? Theme.warning : gap, size: 11.5, weight: .semibold)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.card))
    }
}

// MARK: - How it looks

/// Its fills, borders, corners and shadows, each by its value and by its name in the design.
private struct LookCard: View {
    let node: Node
    let tokens: Inspect.Tokens
    let platform: Inspect.Platform

    var body: some View {
        let text = node.kind == .text
        let fills = text ? Array(node.fills.dropFirst()) : Array(node.fills.reversed())
        let radii = node.radii
        let corners = (node.kind == .rectangle || node.isArtboard) && radii.contains { $0 > 0 }
        let effects = node.opacity < 0.999 || node.blend != nil || node.blur?.on == true
        if !fills.isEmpty || !node.borders.isEmpty || corners || !node.shadows.isEmpty || effects {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(fills.enumerated()), id: \.offset) { _, f in
                    SpecRow(label: "Fill") { paint(f) }
                }
                ForEach(Array(node.borders.enumerated()), id: \.offset) { _, b in
                    SpecRow(label: "Border") {
                        CopyValue(text: number(b.width))
                        Text(position(b.position))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.ink3)
                        ColourValue(color: b.gradient?.stops.first?.color ?? b.color, token: tokens[b.named], platform: platform)
                    }
                }
                if corners {
                    SpecRow(label: "Corners") {
                        let all = Set(radii).count == 1
                        let shown = all ? number(radii[0]) : radii.map(number).joined(separator: " ")
                        CopyValue(text: shown, copy: platform == .css ? radii.map(Inspect.px).joined(separator: " ") : shown)
                        if let t = tokens[node.cornersNamed] { TokenTag(token: t, platform: platform) }
                    }
                }
                ForEach(Array(node.shadows.enumerated()), id: \.offset) { _, s in
                    SpecRow(label: "Shadow") {
                        CopyValue(text: [s.x, s.y, s.blur, s.grown].map(number).joined(separator: " "), copy: Inspect.shadow(s, tokens: Inspect.Tokens.none, platform: platform))
                        Swatch(color: s.color, radius: 4)
                            .frame(width: 16, height: 16)
                        if s.inset == true {
                            Text("Inside")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.ink3)
                        }
                        if let t = tokens[s.named] { TokenTag(token: t, platform: platform) }
                    }
                }
                if node.opacity < 0.999 {
                    SpecRow(label: "Opacity") {
                        CopyValue(text: "\(Int((node.opacity * 100).rounded()))%", copy: DesignTokens.number(node.opacity, 2))
                    }
                }
                if let blend = node.blend {
                    SpecRow(label: "Blend") {
                        CopyValue(text: blend.title, copy: platform == .css ? DesignTokens.kebab(blend.rawValue) : ".\(blend.rawValue)")
                    }
                }
                if let blur = node.blur, blur.on {
                    SpecRow(label: "Blur") {
                        CopyValue(text: number(blur.radius))
                        if blur.background {
                            Text("Behind")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.ink3)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .card(radius: 12)
        }
    }

    @ViewBuilder private func paint(_ f: Fill) -> some View {
        if let image = f.image {
            Image(systemName: "photo")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink2)
                .frame(width: 16, height: 16)
            CopyValue(text: image.asset, copy: Inspect.paint(f, size: node.frame.size, tokens: .none, platform: platform))
        } else if let g = f.gradient, !g.stops.isEmpty {
            LinearGradient(stops: g.stops.sorted { $0.offset < $1.offset }.map { .init(color: Color(nsColor: $0.color.nsColor), location: $0.offset) },
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            CopyValue(text: g.kind == .linear ? String(localized: "Linear") : String(localized: "Radial"),
                      copy: Inspect.paint(f, size: node.frame.size, tokens: .none, platform: platform))
            if let t = tokens[f.named] { TokenTag(token: t, platform: platform) }
        } else {
            ColourValue(color: f.color, token: tokens[f.named], platform: platform)
        }
    }

    private func position(_ p: Border.Position) -> LocalizedStringResource {
        switch p {
        case .inside: "Inside"
        case .center: "Centre"
        case .outside: "Outside"
        }
    }
}

/// The type words are set in: a sample in it, and every measure of it, and the words themselves.
private struct TypeCard: View {
    let node: Node
    let tokens: Inspect.Tokens
    let platform: Inspect.Platform

    var body: some View {
        let style = node.style ?? TextStyle()
        let font = Fonts.font(style)
        let natural = NSLayoutManager().defaultLineHeight(for: font)
        var sample = style
        sample.size = min(max(style.size, 12), 30)
        let token = tokens[style.named]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                Text(verbatim: "Ag")
                    .font(Font(Fonts.font(sample) as CTFont))
                    .foregroundStyle(Theme.ink)
                    .frame(minWidth: 40, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    CopyValue(text: style.family == TextStyle.system ? String(localized: "System") : style.family,
                              copy: platform == .css ? DesignTokens.fontFamily(style.family) : style.family, weight: .semibold)
                    CopyValue(text: "\(style.face) · \(DesignTokens.weight(style.face))", copy: "\(DesignTokens.weight(style.face))", color: Theme.ink2, weight: .regular)
                }
                Spacer(minLength: 0)
                if let token { TokenTag(token: token, platform: platform) }
            }
            .padding(.bottom, 4)
            SpecRow(label: "Size") { CopyValue(text: number(style.size), copy: platform == .css ? Inspect.px(style.size) : number(style.size)) }
            SpecRow(label: "Line Height") {
                if let l = style.lineSpacing {
                    CopyValue(text: number(l), copy: platform == .css ? Inspect.px(l) : number(l))
                } else {
                    Text("Auto")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .padding(.leading, 4)
                    CopyValue(text: number(natural), color: Theme.ink3, weight: .regular)
                }
            }
            if style.tracking != 0 {
                SpecRow(label: "Letter Spacing") {
                    CopyValue(text: number(Inspect.tracking(style)), copy: platform == .css ? "\(DesignTokens.number(Double(style.tracking) / 1000, 3))em" : number(Inspect.tracking(style)))
                    Text(verbatim: "\(DesignTokens.number(Double(style.tracking) / 10, 1))%")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Theme.ink3)
                }
            }
            if style.align != .left {
                SpecRow(label: "Align") {
                    CopyValue(text: String(localized: style.align.title), copy: platform == .css ? style.align.rawValue : style.align.swift)
                }
            }
            if let c = style.letterCase {
                SpecRow(label: "Case") { CopyValue(text: String(localized: c.title), copy: platform == .css ? c.css : c.swift) }
            }
            if let f = node.fills.first {
                SpecRow(label: "Colour") {
                    if let g = f.gradient, !g.stops.isEmpty {
                        CopyValue(text: g.kind == .linear ? String(localized: "Linear") : String(localized: "Radial"),
                                  copy: Inspect.paint(f, size: node.frame.size, tokens: .none, platform: platform))
                    } else {
                        ColourValue(color: f.color, token: tokens[f.named], platform: platform)
                    }
                }
            }
            if let words = node.text, !words.isEmpty {
                WordsBlock(words: words)
                    .padding(.top, 6)
            }
            let runs = Self.runs(of: node)
            if !runs.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                        HStack(spacing: 6) {
                            if let c = run.color {
                                Swatch(color: c, radius: 3).frame(width: 11, height: 11)
                            }
                            Text(verbatim: run.what)
                                .font(.system(size: 11.5).monospacedDigit())
                                .foregroundStyle(Theme.ink2)
                                .lineLimit(1)
                            Text(verbatim: "“\(run.words)”")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.ink3)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(minHeight: 18)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .card(radius: 12)
    }

    /// The words set otherwise than the layer's type: how, each look once, with words that have it.
    static func runs(of node: Node) -> [(what: String, color: RGBA?, words: String)] {
        guard node.spans != nil, let style = node.style else { return [] }
        var seen: [TextLook] = []
        var out: [(String, RGBA?, String)] = []
        for run in node.runs where !run.look.isPlain {
            var look = run.look
            look.list = nil
            guard !look.isPlain, !seen.contains(look) else { continue }
            seen.append(look)
            var parts: [String] = []
            if let f = look.family { parts.append(f == TextStyle.system ? String(localized: "System") : f) }
            if let f = look.face, f != style.face || look.family != nil { parts.append(f) }
            if let s = look.size { parts.append(CanvasView.number(s)) }
            if let c = look.color { parts.append(Inspect.hex(c)) }
            if look.underline == true { parts.append(String(localized: "Underline")) }
            if look.strikethrough == true { parts.append(String(localized: "Strikethrough")) }
            let words = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append((parts.joined(separator: " · "), look.color, String(words.prefix(40))))
            if out.count >= 6 { break }
        }
        return out
    }
}

private extension LetterCase {
    var css: String {
        switch self {
        case .upper: "uppercase"
        case .lower: "lowercase"
        case .title: "capitalize"
        case .smallCaps: "small-caps"
        }
    }

    var swift: String {
        switch self {
        case .upper: ".textCase(.uppercase)"
        case .lower: ".textCase(.lowercase)"
        case .title: ".textCase(nil) // capitalised as typed"
        case .smallCaps: ".font(.body.smallCaps())"
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .upper: "Uppercase"
        case .lower: "Lowercase"
        case .title: "Title Case"
        case .smallCaps: "Small Caps"
        }
    }
}

private extension TextAlign {
    var title: LocalizedStringResource {
        switch self {
        case .left: "Left"
        case .center: "Centre"
        case .right: "Right"
        case .justify: "Justify"
        }
    }

    var swift: String {
        switch self {
        case .left: ".leading"
        case .center: ".center"
        case .right: ".trailing"
        case .justify: ".leading // justified"
        }
    }
}

/// The words of a text layer, copied whole with a click.
private struct WordsBlock: View {
    let words: String
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Text(verbatim: words)
            .prose(12)
            .foregroundStyle(Theme.ink)
            .lineLimit(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.pencilWash : Theme.ink.opacity(0.035)))
            .overlay(alignment: .topTrailing) {
                if copied {
                    CheckMark(size: 9, color: Theme.pencil)
                        .padding(6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture {
                InspectCopy.put(words)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
            .animation(Theme.quick, value: hovering)
            .animation(Theme.pop, value: copied)
    }
}

/// A screen's layout grid, as columns, rows and baseline are set.
private struct GridSpecCard: View {
    let grid: LayoutGrid
    let board: Node

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let c = grid.columns { track("Columns", c, along: board.frame.width) }
            if let r = grid.rows { track("Rows", r, along: board.frame.height) }
            if let b = grid.baseline {
                SpecRow(label: "Baseline") { CopyValue(text: number(b.step)) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .card(radius: 12)
    }

    private func track(_ label: LocalizedStringResource, _ t: LayoutGrid.Track, along length: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SpecRow(label: label) {
                CopyValue(text: "\(t.count)", weight: .semibold)
                Text(verbatim: "×").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                CopyValue(text: number(t.size(along: length)))
            }
            SpecRow(label: "Gutter") { CopyValue(text: number(t.gutter)) }
            SpecRow(label: "Margin") { CopyValue(text: number(t.margin)) }
        }
    }
}

// MARK: - As code

/// The layer as code, for the web or for SwiftUI, its named looks by their tokens.
private struct CodeCard: View {
    let node: Node
    let doc: BezzleDocument
    let tokens: Inspect.Tokens
    @Binding var platformName: String
    @State private var copied = false

    var body: some View {
        let platform = Inspect.Platform(rawValue: platformName) ?? .css
        let code = Inspect.code(node, in: doc, tokens: tokens, for: platform)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                CodeGlyph()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(Theme.ink2)
                Text("Code")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                PlatformSwitch(platformName: $platformName)
            }
            .frame(height: 22)
            ScrollView(.horizontal) {
                Text(Self.tinted(code))
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(10)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            Button {
                InspectCopy.put(code)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
            } label: {
                HStack(spacing: 7) {
                    if copied {
                        CheckMark(size: 10, color: Theme.onInk, weight: 1.8)
                            .transition(.scale.combined(with: .opacity))
                    }
                    Text(copied ? "Copied" : platform == .css ? "Copy CSS" : "Copy SwiftUI")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(Theme.onInk)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink))
            }
            .buttonStyle(Pressable())
        }
        .padding(12)
        .card(radius: 12)
        .animation(Theme.quick, value: copied)
        .animation(Theme.spring, value: platformName)
    }

    /// The code with what is quiet in it quieter: comments faint, properties and modifiers in the
    /// second ink, the design's tokens in pencil.
    static func tinted(_ code: String) -> AttributedString {
        var out = AttributedString(code)
        out.foregroundColor = Theme.ink
        let ns = code as NSString
        func paint(_ pattern: String, _ color: Color, group: Int = 0) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            for m in re.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                let r = m.range(at: group)
                guard r.location != NSNotFound, let range = Range(r, in: out) else { continue }
                out[range].foregroundColor = color
            }
        }
        paint(#"^\s*([a-z-]+):"#, Theme.ink2, group: 1)
        paint(#"\.([a-zA-Z]+)(?=\()"#, Theme.ink2, group: 1)
        paint(#"var\(--[a-z0-9-]+\)|Tokens\.[A-Za-z]+\.[A-Za-z_`0-9]+|\.text-[a-z0-9-]+"#, Theme.pencil)
        paint(#"/\*.*?\*/|//[^\n]*"#, Theme.ink3)
        return out
    }
}

/// CSS or SwiftUI: two words in a small well, the one chosen on a card.
private struct PlatformSwitch: View {
    @Binding var platformName: String
    @Namespace private var space

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Inspect.Platform.allCases, id: \.self) { p in
                let on = platformName == p.rawValue
                Text(verbatim: p.title)
                    .font(.system(size: 11, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Theme.ink : Theme.ink2)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background {
                        if on { Color.clear.card(radius: 5).matchedGeometryEffect(id: "platform", in: space) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { platformName = p.rawValue }
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .well(radius: 7)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: platformName)
    }
}

// MARK: - As a file

/// Small pictures of layers, made again only when a layer changes.
@MainActor
final class LayerPictures {
    static let shared = LayerPictures()
    private var kept: [UUID: (node: Node, image: CGImage, scale: CGFloat)] = [:]

    /// The layer drawn sharp enough to show at no more than its own size in `box`, and how many
    /// pixels it has to a point.
    func image(of id: UUID, store: DocumentStore, fitting box: CGSize) -> (image: CGImage, scale: CGFloat)? {
        guard let item = InspectCopy.item(id, store: store) else { return nil }
        if let k = kept[id], k.node == item.node { return (k.image, k.scale) }
        let f = item.node.frame
        let scale = min(2, max(0.05, min(box.width * 2 / max(f.width, 1), box.height * 2 / max(f.height, 1))))
        guard let (image, _) = item.picture(scale: scale, opaque: false, assets: store.assets) else { return nil }
        if kept.count > 200 { kept.removeAll() }
        kept[id] = (item.node, image, scale)
        return (image, scale)
    }
}

/// The layer to take away as a file: its picture, dragged out to the Finder or into code, in the
/// format and size chosen, or copied.
private struct AssetCard: View {
    let store: DocumentStore
    let node: Node
    @AppStorage("inspect.assetFormat") private var formatName = ExportFormat.png.rawValue
    @AppStorage("inspect.assetScale") private var scale = 2.0
    @State private var copied = false

    var body: some View {
        let format = ExportFormat(rawValue: formatName).flatMap { [.png, .svg, .pdf].contains($0) ? $0 : nil } ?? .png
        VStack(alignment: .leading, spacing: 10) {
            DragPicture(store: store, id: node.id, format: format, scale: CGFloat(scale))
            HStack(spacing: 3) {
                ForEach([ExportFormat.png, .svg, .pdf], id: \.self) { f in
                    Chip(title: f.title, on: format == f) { formatName = f.rawValue }
                }
                Spacer(minLength: 6)
                if format.isPicture {
                    ForEach([1.0, 2.0, 3.0], id: \.self) { s in
                        Chip(title: "\(Int(s))×", on: scale == s) { scale = s }
                    }
                }
            }
            Button {
                InspectCopy.picture(of: node.id, as: format, scale: format.isPicture ? CGFloat(scale) : 1, store: store)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
            } label: {
                HStack(spacing: 6) {
                    if copied {
                        CheckMark(size: 10, color: Theme.pencil)
                            .transition(.scale.combined(with: .opacity))
                    }
                    Text(copied ? "Copied" : "Copy")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(copied ? Theme.pencil : Theme.ink)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .card(radius: 8)
            }
            .buttonStyle(Pressable())
        }
        .padding(12)
        .card(radius: 12)
        .animation(Theme.quick, value: copied)
        .animation(Theme.quick, value: formatName)
    }
}

/// A layer's picture on a checkerboard, lifted a little while pointed at, to drag out as a file.
private struct DragPicture: View {
    let store: DocumentStore
    let id: UUID
    let format: ExportFormat
    let scale: CGFloat
    var height: CGFloat = 124
    @State private var hovering = false

    /// Whether what it is painted or written in is light: then shown on a dark board.
    private var light: Bool {
        guard let n = store.seenDoc.node(id), !n.isArtboard else { return false }
        let paint = n.kind == .text ? n.fills.first : (n.fills.last ?? n.children.compactMap { $0.fills.last }.first)
        guard let c = paint?.color, paint?.image == nil else { return false }
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b > 0.8 && c.a > 0.3
    }

    var body: some View {
        let width = Inspector.content
        let picture = LayerPictures.shared.image(of: id, store: store, fitting: CGSize(width: width - 24, height: height - 24))
        ZStack {
            if light {
                // Light on light would not show: a dark board under what is light.
                DarkChecker(square: 6)
            } else {
                Checkerboard(square: 6)
                    .opacity(0.5)
            }
            if let (image, scale) = picture {
                // At its own size, or smaller to fit.
                let w = CGFloat(image.width) / scale, h = CGFloat(image.height) / scale
                let k = min((width - 24) / max(w, 1), (height - 24) / max(h, 1), 1)
                Image(decorative: image, scale: scale)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: w * k, height: h * k)
                    .shadow(color: Theme.shadow.opacity(hovering ? 0.25 : 0.1), radius: hovering ? 8 : 3, y: hovering ? 4 : 1)
                    .scaleEffect(hovering ? 1.03 : 1)
                    .offset(y: hovering ? -2 : 0)
            }
            // A file's corner, folded, where it is taken hold of.
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .opacity(hovering ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            (inside ? NSCursor.openHand : NSCursor.arrow).set()
        }
        .onDrag {
            guard let url = InspectCopy.dragged(id, as: format, scale: format.isPicture ? scale : 1, store: store) else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .help(Text(verbatim: "\(format.title)\(format.isPicture ? " @\(Int(scale))x" : "")"))
    }
}

/// A checkerboard of dark squares, for what is light.
private struct DarkChecker: View {
    var square: CGFloat = 6

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.2)))
            var p = Path()
            for row in 0..<Int(ceil(size.height / square)) {
                for col in 0..<Int(ceil(size.width / square)) where (row + col) % 2 == 1 {
                    p.addRect(CGRect(x: CGFloat(col) * square, y: CGFloat(row) * square, width: square, height: square))
                }
            }
            ctx.fill(p, with: .color(Color(white: 0.25)))
        }
    }
}

private struct Chip: View {
    let title: String
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(verbatim: title)
            .font(.system(size: 11, weight: on ? .semibold : .medium))
            .foregroundStyle(on ? Theme.pencil : Theme.ink2)
            .fixedSize()
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Theme.pencilWash : Theme.ink.opacity(hovering ? 0.06 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(on ? Theme.pencil.opacity(0.5) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .animation(Theme.quick, value: hovering)
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Nothing picked

/// The design's colours: those it names first, by their names, then the others it uses most.
private struct PaletteCard: View {
    let store: DocumentStore
    let tokens: Inspect.Tokens
    let platform: Inspect.Platform

    var body: some View {
        let seen = store.seenDoc
        let named = DesignTokens.styles(seen).filter { $0.kind == .colour }
        let used = Self.used(in: seen, besides: named.compactMap { $0.look.paint?.color })
        if !named.isEmpty || !used.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 4), spacing: 10) {
                ForEach(named, id: \.id) { style in
                    if let paint = style.look.paint {
                        SwatchTile(paint: paint, title: style.name, copy: tokens[style.id]?.code(platform) ?? Inspect.hex(paint.color))
                    }
                }
                ForEach(Array(used.enumerated()), id: \.offset) { _, c in
                    SwatchTile(paint: ColourLook(color: c), title: c.a < 0.999 ? "\(c.hex) \(Int((c.a * 100).rounded()))%" : "#" + c.hex,
                               copy: platform == .css ? Inspect.hex(c) : Inspect.swiftColor(c))
                }
            }
            .padding(12)
            .card(radius: 12)
        }
    }

    /// The colours layers are painted, edged and written in, most used first, those named left out.
    static func used(in doc: BezzleDocument, besides named: [RGBA], limit: Int = 10) -> [RGBA] {
        var count: [RGBA: Int] = [:]
        func visit(_ n: Node) {
            guard !n.hidden else { return }
            for f in n.fills where f.image == nil && f.gradient == nil && f.named == nil { count[f.color, default: 0] += 1 }
            for b in n.borders where b.named == nil && b.gradient == nil { count[b.color, default: 0] += 1 }
            n.children.forEach(visit)
        }
        doc.nodes.forEach(visit)
        let skip = Set(named.map(\.hex))
        var out: [RGBA] = []
        for (c, _) in count.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key.hex < $1.key.hex }) {
            guard !skip.contains(c.hex), !out.contains(where: { $0.hex == c.hex && abs($0.a - c.a) < 0.01 }) else { continue }
            out.append(c)
            if out.count >= limit { break }
        }
        return out
    }
}

private struct SwatchTile: View {
    let paint: ColourLook
    let title: String
    let copy: String
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let g = paint.gradient, !g.stops.isEmpty {
                    LinearGradient(stops: g.stops.sorted { $0.offset < $1.offset }.map { .init(color: Color(nsColor: $0.color.nsColor), location: $0.offset) },
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Swatch(color: paint.color, radius: 8)
                }
                if copied {
                    CheckMark(size: 12, color: paint.color.hsb.b > 0.6 && paint.color.hsb.s < 0.5 ? Theme.ink : .white, weight: 2)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(height: 34)
            .scaleEffect(hovering ? 1.08 : 1)
            .shadow(color: Theme.shadow.opacity(hovering ? 0.2 : 0), radius: 5, y: 2)
            Text(verbatim: title)
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.tail)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            InspectCopy.put(copy)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        }
        .help(Text(verbatim: copy))
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hovering)
        .animation(Theme.pop, value: copied)
    }
}

/// The design's type: each named type as a sample of itself, then the others it sets most.
private struct TypeSamplesCard: View {
    let store: DocumentStore
    let tokens: Inspect.Tokens
    let platform: Inspect.Platform

    var body: some View {
        let seen = store.seenDoc
        let named = DesignTokens.styles(seen).filter { $0.kind == .text }
        let used = Self.used(in: seen)
        if !named.isEmpty || !used.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(named.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Hairline() }
                    if let t = s.look.type {
                        TypeSample(style: t.style, title: s.name, copy: tokens[s.id]?.code(platform) ?? "")
                    }
                }
                ForEach(Array(used.enumerated()), id: \.offset) { i, style in
                    if i > 0 || !named.isEmpty { Hairline() }
                    TypeSample(style: style, title: nil, copy: Self.describe(style, platform))
                }
            }
            .card(radius: 12)
        }
    }

    static func describe(_ s: TextStyle, _ platform: Inspect.Platform) -> String {
        var t = Node(kind: .text, name: "Text", frame: .zero)
        t.style = s
        t.text = ""
        t.fill.on = false
        return Inspect.code(t, in: BezzleDocument(), tokens: .none, for: platform)
    }

    /// The type layers are set in that has no name, the most used first.
    static func used(in doc: BezzleDocument, limit: Int = 6) -> [TextStyle] {
        struct Key: Hashable { let family: String, face: String, size: CGFloat, line: CGFloat? }
        var count: [Key: (TextStyle, Int)] = [:]
        func visit(_ n: Node) {
            guard !n.hidden else { return }
            if n.kind == .text, let s = n.style, s.named == nil {
                let k = Key(family: s.family, face: s.face, size: s.size, line: s.lineSpacing)
                count[k] = (count[k]?.0 ?? s, (count[k]?.1 ?? 0) + 1)
            }
            n.children.forEach(visit)
        }
        doc.nodes.forEach(visit)
        return count.values.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.size > $1.0.size }.prefix(limit).map(\.0)
    }
}

private struct TypeSample: View {
    let style: TextStyle
    let title: String?
    let copy: String
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        var sample = style
        sample.size = min(max(style.size, 11), 22)
        let line = style.lineSpacing.map { " / \(CanvasView.number($0))" } ?? ""
        let family = style.family == TextStyle.system ? String(localized: "System") : style.family
        // Named, by its name; else by what it is, each in itself.
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title ?? "\(family) \(style.face)")
                    .font(Font(Fonts.font(sample) as CTFont))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(verbatim: title == nil ? "\(CanvasView.number(style.size))\(line)" : "\(family) \(style.face) · \(CanvasView.number(style.size))\(line)")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if copied {
                CheckMark(size: 10, color: Theme.pencil)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(hovering ? Theme.pencilWash : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            InspectCopy.put(copy)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        }
        .help(Text(verbatim: copy))
        .animation(Theme.quick, value: hovering)
        .animation(Theme.pop, value: copied)
    }
}

/// What the design marks for export, each to drag out as its first preset makes it, and all of
/// it exported at once.
private struct MarkedAssetsCard: View {
    let store: DocumentStore

    var body: some View {
        let items = ExportItem.marked(in: store.doc, seen: store.seenDoc).filter { !$0.node.isArtboard }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 3), spacing: 10) {
                    ForEach(Array(items.prefix(24).enumerated()), id: \.offset) { _, item in
                        let preset = item.node.exports?.first ?? ExportPreset()
                        VStack(spacing: 4) {
                            DragPicture(store: store, id: item.node.id, format: preset.format,
                                        scale: CGFloat(preset.size.plainScale ?? 1), height: 64)
                            Text(verbatim: item.node.name)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.ink2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .onTapGesture { store.selection = [item.node.id] }
                    }
                }
                CardButton(title: "Export…", symbol: "square.and.arrow.up", height: 28) { store.exporting = true }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .card(radius: 12)
        }
    }
}

extension Inspect.Tokens {
    /// No names at all: looks written by their values.
    static var none: Inspect.Tokens { Inspect.Tokens(BezzleDocument()) }
}
