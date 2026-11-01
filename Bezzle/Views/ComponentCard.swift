import SwiftUI
import AppKit

/// A copy of a component, or a layer in one, selected, as a card. Folded, it names the component
/// and turns from this copy to the next wherever it is used. Open, it names the component and shows
/// its variants, each drawn as this copy would look as it: the pointer on one shows the copy turning
/// into it on the canvas, a click makes it so, and the last makes a new one. Pulled off, the copy
/// is unlinked: a group like any other, as it looks. Pointing at the card outlines every copy on
/// the canvas. See `Instance`.
struct ComponentCard: View {
    let store: DocumentStore
    let copy: Node
    /// Whether the copy itself is selected rather than a layer in it: only then does pulling the
    /// card off unlink it.
    let whole: Bool

    var body: some View {
        if let master = store.master(of: copy) {
            let all = store.copiesInOrder(of: master.id)
            let index = all.firstIndex(of: copy.id) ?? 0
            AspectCard(aspect: .component, title: "Component", summary: summary(master),
                       remove: whole ? { store.unlinkComponent([copy.id]) } : nil, removal: "Unlink from component",
                       accessory: all.count > 1 ? AnyView(turner(index, of: all.count)) : nil) {
                ComponentGlyph()
                    .foregroundStyle(Theme.linked)
            } picks: {
                VStack(alignment: .leading, spacing: 10) {
                    EntryField(text: master.name, placeholder: String(localized: "Name"), help: "What the component is called") { typed in
                        guard !typed.isEmpty else { return nil }
                        store.renameComponent(master.id, to: typed)
                        return typed
                    }
                    VariantTiles(store: store, copy: copy, master: master)
                    if store.hasOwnLooks(copy) {
                        TextButton(title: "Look Like the Others") { store.resetCopy(copy.id) }
                            .help(Text("Lets this copy follow its component again in everything it keeps of its own, but its words and pictures"))
                    }
                }
            }
        }
    }

    /// The variant it shows, when there are several; else its name, unless the line is taken by
    /// the turner, as the canvas names it over the copy.
    private func summary(_ master: Node) -> String {
        if Components.variants(of: master).count > 1 { return Components.name(of: copy.instance?.variant, in: master) }
        return store.doc.copies(of: master.id).count > 1 ? "" : master.name
    }

    private func turner(_ index: Int, of count: Int) -> some View {
        HStack(spacing: 2) {
            IconButton(symbol: "chevron.left", help: "The copy before", size: 22) { store.goToCopy(-1) }
            // Always one line as wide as it needs: the summary beside it gives way instead.
            Text("\(index + 1) of \(count)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 44)
                .contentTransition(.numericText())
                .animation(Theme.quick, value: index)
            IconButton(symbol: "chevron.right", help: "The copy after", size: 22) { store.goToCopy(1) }
        }
    }
}

/// A component's variants as tiles, three to a row, the one the copy shows ringed; then one that
/// makes a new variant of the copy as it looks.
private struct VariantTiles: View {
    let store: DocumentStore
    let copy: Node
    let master: Node
    @State private var renaming: Int??
    @State private var draft = ""

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        let variants = Components.variants(of: master)
        let current = Components.variant(copy.instance?.variant, of: master)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(variants.indices, id: \.self) { i in
                let v = variants[i]
                VariantTile(store: store, copy: copy, master: master, variant: v, chosen: v == current,
                            renaming: renaming == .some(v), draft: $draft) {
                    renaming = .some(v)
                    draft = Components.name(of: v, in: master)
                } done: { name in
                    if let name { store.renameVariant(v, of: master.id, to: name) }
                    renaming = nil
                }
            }
            NewVariantTile { store.addVariant(from: copy.id) }
        }
        .animation(Theme.spring, value: variants.count)
    }
}

private struct VariantTile: View {
    let store: DocumentStore
    let copy: Node
    let master: Node
    let variant: Int?
    let chosen: Bool
    let renaming: Bool
    @Binding var draft: String
    let rename: () -> Void
    let done: (String?) -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.card)
                if let image = ComponentPictures.image(of: copy, as: variant, in: master, store: store, size: CGSize(width: 64, height: 40)) {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(3)
                }
            }
            .frame(height: 44)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(chosen ? Theme.linked : Theme.hairline, lineWidth: chosen ? 2 : 1)
            }
            .shadow(color: Theme.shadow.opacity(hovering ? 0.16 : 0.06), radius: hovering ? 6 : 2, y: hovering ? 3 : 1)
            .offset(y: hovering ? -1.5 : 0)
            if renaming {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onSubmit { done(draft) }
                    .onExitCommand { done(nil) }
                    .onAppear { focused = true }
                    .onChange(of: focused) { _, now in if !now { done(draft) } }
            } else {
                Text(Components.name(of: variant, in: master))
                    .font(.system(size: 11))
                    .foregroundStyle(chosen ? Theme.linked : Theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .contentShape(Rectangle())
        .onHover { on in
            hovering = on
            // The copy turned into this variant on the canvas, before it is chosen.
            if on, !chosen {
                let id = copy.id, master = master, v = variant
                store.showPreview("component.tile", reshaping: { doc in
                    let before = doc
                    doc.update(id) { $0 = Components.switched($0, to: v, in: master) }
                    doc.syncComponents(since: before)
                })
            } else {
                store.showPreview("component.tile", reshaping: nil)
            }
        }
        .onTapGesture(count: 2) { rename() }
        .onTapGesture {
            store.showPreview("component.tile", reshaping: nil)
            store.setVariant(variant, for: [copy.id])
        }
        .contextMenu {
            Button("Rename") { rename() }
            if let v = variant {
                Button("Delete Variant") { store.removeVariant(v, of: master.id) }
            }
        }
        .animation(Theme.quick, value: hovering)
        .animation(Theme.quick, value: chosen)
        .help(Text("Shows this copy as \(Components.name(of: variant, in: master))"))
    }
}

/// A dashed tile with a plus: a new variant, of the copy as it looks now.
private struct NewVariantTile: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(hovering ? Theme.linked : Theme.ink4, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.linkedWash : .clear))
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(hovering ? Theme.linked : Theme.ink3)
                        .scaleEffect(hovering ? 1.15 : 1)
                }
                .frame(height: 44)
            Text("New Variant")
                .font(.system(size: 11))
                .foregroundStyle(hovering ? Theme.linked : Theme.ink3)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .animation(Theme.pop, value: hovering)
        .help(Text("A new variant of the component, as this copy looks now. What is changed in its copies stays in it."))
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("New Variant"))
    }
}

/// A layer of a copy that keeps something of its own, whatever the other copies do: what, and how
/// to let it follow them again.
struct CopyLayerCard: View {
    let store: DocumentStore
    let node: Node

    var body: some View {
        AspectCard(aspect: .component, title: "Only in this copy", summary: PostLayerCard.names(node.own ?? []),
                   accessory: AnyView(TextButton(title: "Follow the Others") { store.followComponent([node.id]) })) {
            Image(systemName: "pin")
                .font(.system(size: 11, weight: .medium))
        }
    }
}

/// Four small diamonds standing in a diamond: a component.
struct ComponentGlyph: View {
    var size: CGFloat = 13

    var body: some View {
        Canvas { ctx, s in
            let c = CGPoint(x: s.width / 2, y: s.height / 2), r = s.width * 0.25, d = s.width * 0.2
            for p in [CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x + r, y: c.y), CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x - r, y: c.y)] {
                let diamond = Path { q in
                    q.move(to: CGPoint(x: p.x, y: p.y - d))
                    q.addLine(to: CGPoint(x: p.x + d, y: p.y))
                    q.addLine(to: CGPoint(x: p.x, y: p.y + d))
                    q.addLine(to: CGPoint(x: p.x - d, y: p.y))
                    q.closeSubpath()
                }
                ctx.fill(diamond, with: .foreground)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Copies drawn as each of their component's variants, small, made once per change to the design.
@MainActor
enum ComponentPictures {
    private static var made: [String: CGImage] = [:]
    private static var version = -1

    static func image(of copy: Node, as variant: Int?, in master: Node, store: DocumentStore, size: CGSize) -> CGImage? {
        if store.version != version {
            made = [:]
            version = store.version
        }
        let key = "\(copy.id)/\(variant ?? 0)/\(Int(size.width))x\(Int(size.height))"
        if let hit = made[key] { return hit }
        var shown = Components.build(Components.switched(copy, to: variant, in: master), master: master, masterWas: nil, masters: store.doc.mastersByID)
        shown.frame.origin = .zero
        shown.hidden = false
        var doc = BezzleDocument()
        doc.nodes = [shown]
        doc.fitGroups()
        let image = Renderer.thumbnail(of: doc, size: size, scale: 2, assets: store.assets)
        made[key] = image
        return image
    }

    /// A component as a new copy of it would look, for the resources panel.
    static func image(of master: Node, store: DocumentStore, size: CGSize) -> CGImage? {
        if store.version != version {
            made = [:]
            version = store.version
        }
        let key = "\(master.id)/master/\(Int(size.width))x\(Int(size.height))"
        if let hit = made[key] { return hit }
        var doc = BezzleDocument()
        doc.nodes = [Components.newCopy(of: master, at: .zero, masters: store.doc.mastersByID)]
        doc.fitGroups()
        let image = Renderer.thumbnail(of: doc, size: size, scale: 2, assets: store.assets)
        made[key] = image
        return image
    }
}
