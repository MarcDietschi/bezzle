import SwiftUI
import AppKit

/// How the design's named looks show in the inspector. A card whose look has a name says the name
/// where it says what the look comes to, in pencil, and its picture is ringed. Open, it offers the
/// design's styles of its kind first, and to name its own look. See `Style`.
extension Aspect {
    /// Where on the selected layers the card's look lies, when it is one that can have a name.
    var stylePlace: StylePlace? {
        switch self {
        case .fill(let slot): .fill(slot)
        case .background: .fill(0)
        case .border(let slot): .border(slot)
        case .shadow(let slot): .shadow(slot)
        case .text: .text
        case .corners: .corners
        default: nil
        }
    }
}

// MARK: - Small pictures

/// A style's look in small: its colour, its type, its shadow or its corners.
struct StyleGlyph: View {
    let look: StyleLook
    var size: CGFloat = 14

    var body: some View {
        switch look {
        case .colour(let p):
            FillSwatch(fill: Fill(color: p.color, gradient: p.gradient), radius: size * 0.3)
                .frame(width: size, height: size)
        case .text(let t):
            Text(verbatim: "Aa")
                .font(StyleFont.font(t, size: size * 0.92))
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: size, minHeight: size)
        case .shadow(let s):
            ShadowGlyph(y: s.y, blur: s.blur, inset: s.inset == true)
                .frame(width: max(size, 16), height: size)
        case .corners(let c):
            CornerGlyph(radius: c.radius, smooth: (c.smoothing ?? 0) > 0)
                .frame(width: size, height: size)
        }
    }
}

/// A named type's own font, at a size of the inspector's.
enum StyleFont {
    static func font(_ t: TypeLook, size: CGFloat) -> Font {
        var s = t.style
        s.size = size
        return Font(Fonts.font(s) as CTFont)
    }
}

/// The mark of a name: a small pencil diamond, as a seal pressed into the card.
struct NameMark: View {
    var size: CGFloat = 5.5
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(Theme.pencil)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(45))
            .frame(width: size * 1.5, height: size * 1.5)
    }
}

/// A name pressed in as a stamp is: coming down bigger and soft onto the card, and lifting off.
struct InkStamp: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .scaleEffect(phase.isIdentity ? 1 : phase == .willAppear ? 1.4 : 0.92, anchor: .trailing)
            .blur(radius: phase.isIdentity ? 0 : 5)
            .opacity(phase.isIdentity ? 1 : 0)
    }
}

/// What a folded card says of a named look: its name, after the mark.
struct NamedSummary: View {
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            NameMark()
            Text(verbatim: name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(Theme.pencil)
    }
}

/// The ring round a named card's picture, drawn on as it is named.
struct NameRing: View {
    let on: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 7.5, style: .continuous)
            .trim(from: 0, to: on ? 1 : 0)
            .stroke(Theme.pencil.opacity(0.75), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            .frame(width: 26, height: 26)
            .opacity(on ? 1 : 0)
            .animation(on ? .easeInOut(duration: 0.5) : .easeOut(duration: 0.15), value: on)
            .allowsHitTesting(false)
    }
}

// MARK: - In an open card

/// The design's styles a card's look can be, first in the open card: one click gives the selection
/// one, pointing at one shows it on the canvas, and the dashed one names the look it has.
struct StyleRow: View {
    @Environment(DocumentStore.self) private var store
    let place: StylePlace

    var body: some View {
        let options = store.styles(for: place)
        let current = store.sharedStyle(at: place)
        let dark = store.showsDark(place)
        Flow(spacing: 6) {
            ForEach(options) { style in
                StyleChip(place: place, style: style, active: style.id == current?.id, dark: dark)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            if current == nil, let look = store.holding(place).first.flatMap(place.look(of:)) {
                NameChip(place: place, look: look)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(Theme.pop, value: options.map(\.id))
        .animation(Theme.pop, value: current?.id)
        .geometryGroup()
    }
}

/// One of the design's styles, to give the selection.
private struct StyleChip: View {
    @Environment(DocumentStore.self) private var store
    let place: StylePlace
    let style: Style
    let active: Bool
    /// Whether the selection lies on a dark artboard, where the style shows its dark look.
    var dark = false
    @State private var hovering = false
    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            // A type says its own name in itself; the rest show their look beside it.
            if style.kind != .text {
                StyleGlyph(look: style.look(dark: dark), size: 13)
                    .foregroundStyle(active ? Theme.pencil : Theme.ink2)
            }
            if let draft {
                TextField("", text: Binding(get: { draft }, set: { self.draft = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .focused($focused)
                    .frame(width: 110)
                    .onSubmit { commit() }
                    .onExitCommand { self.draft = nil; StyleFocus.release(store) }
            } else if let t = style.look.type {
                Text(verbatim: style.name)
                    .font(StyleFont.font(t, size: min(max(t.size * 0.55, 11.5), 15)))
                    .lineLimit(1)
            } else {
                Text(verbatim: style.name)
                    .font(.system(size: 12, weight: active ? .medium : .regular))
                    .lineLimit(1)
            }
            if active && hovering && draft == nil {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.pencil.opacity(0.8))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(Theme.pop) { store.unname(at: place) } }
                    .help("Keep the look, without its name")
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .foregroundStyle(active ? Theme.pencil : Theme.ink)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? Theme.pencilWash : Theme.ink.opacity(hovering ? 0.075 : 0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(active ? Theme.pencil.opacity(0.65) : Theme.hairline, lineWidth: active ? 1 : 0.5)
        }
        .scaleEffect(hovering && !active ? 1.03 : 1)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(Theme.quick) { hovering = inside }
            store.styleShow.pointed = inside ? style.id : (store.styleShow.pointed == style.id ? nil : store.styleShow.pointed)
            if !active { store.showPreview("style-\(style.id)", inside ? preview : nil) }
        }
        .onTapGesture {
            guard !active else { return }
            store.showPreview("style-\(style.id)", nil)
            withAnimation(Theme.pop) { store.use(style, at: place) }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { rename() })
        .onChange(of: focused) { _, now in if !now, draft != nil { commit() } }
        .onDisappear {
            if hovering {
                store.showPreview("style-\(style.id)", nil)
                if store.styleShow.pointed == style.id { store.styleShow.pointed = nil }
            }
        }
        .help(Text(active ? "Double-click to rename" : "Use this style"))
        .accessibilityLabel(Text(verbatim: style.name))
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    private var preview: (inout Node) -> Void {
        let look = style.look(dark: dark), place = place
        return { n in if place.look(of: n) != nil, place.takes(look, in: n) { place.apply(look, to: &n) } }
    }

    private func rename() {
        draft = style.name
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        if let draft { store.renameStyle(style.id, to: draft) }
        draft = nil
        StyleFocus.release(store)
    }
}

/// The dashed chip that names the look a card shows: a click turns it into a field with a name
/// already in it, and Return gives the look that name.
private struct NameChip: View {
    @Environment(DocumentStore.self) private var store
    let place: StylePlace
    let look: StyleLook
    @State private var hovering = false
    @State private var draft: String?
    @State private var suggested = ""
    @FocusState private var focused: Bool

    var body: some View {
        let naming = draft != nil
        HStack(spacing: 6) {
            if naming {
                StyleGlyph(look: look, size: 13)
                    .foregroundStyle(Theme.pencil)
                TextField("", text: Binding(get: { draft ?? "" }, set: { draft = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                    .frame(width: 128)
                    .onSubmit { commit() }
                    .onExitCommand { cancel() }
                NameMark(size: 5)
                    .opacity(0.6)
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 9.5, weight: .bold))
                Text("Style")
                    .font(.system(size: 12))
            }
        }
        .foregroundStyle(hovering || naming ? Theme.ink : Theme.ink2)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(naming ? Theme.card : .clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(naming ? Theme.pencil.opacity(0.7) : Theme.ink.opacity(hovering ? 0.28 : 0.16),
                              style: StrokeStyle(lineWidth: 1, dash: naming ? [] : [3, 2.5]))
        }
        .shadow(color: Theme.shadow.opacity(naming ? 0.12 : 0), radius: 6, y: 2)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Theme.quick) { hovering = inside } }
        .onTapGesture { if !naming { begin() } }
        .onChange(of: focused) { _, now in
            // Clicked away from: kept when a name was typed, let go when the one offered was left.
            if !now, let draft { draft == suggested ? cancel() : commit() }
        }
        .animation(Theme.pop, value: naming)
        .help("Give this look a name, to use it on other layers and change it everywhere at once")
    }

    private func begin() {
        suggested = store.suggestedName(for: look)
        withAnimation(Theme.pop) { draft = suggested }
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        guard let name = draft else { return }
        draft = nil
        withAnimation(Theme.pop) { _ = store.nameLook(at: place, name) }
        StyleFocus.release(store)
    }

    private func cancel() {
        withAnimation(Theme.pop) { draft = nil }
        StyleFocus.release(store)
    }
}

enum StyleFocus {
    /// Gives the keys back to the canvas once a name is typed, so the arrow keys move layers again.
    static func release(_ store: DocumentStore) {
        DispatchQueue.main.async {
            if let canvas = store.canvas, let window = canvas.window { window.makeFirstResponder(canvas) }
        }
    }
}
