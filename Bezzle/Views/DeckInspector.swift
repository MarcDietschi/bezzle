import SwiftUI

/// A stack's posts: which is in front, of how many, and turning from one to the next, right on
/// its folded line. Adding, seeing them all and the rest are on the canvas, on the stack itself.
/// See `Deck`.
struct DeckCard: View {
    let store: DocumentStore
    let board: Node

    var body: some View {
        let (index, count) = store.place(in: board)
        AspectCard(aspect: .deck, title: "Post", summary: "", accessory: AnyView(turner(index, of: count))) {
            Image(systemName: "square.stack")
                .font(.system(size: 11.5, weight: .medium))
        }
    }

    private func turner(_ index: Int, of count: Int) -> some View {
        HStack(spacing: 2) {
            IconButton(symbol: "chevron.left", help: "The post before (Page Up)", size: 22) { store.turnPage(by: -1) }
                .opacity(index > 0 ? 1 : 0.35)
                .allowsHitTesting(index > 0)
            // Always one line as wide as it needs: the summary beside it gives way instead.
            Text("\(index + 1) of \(count)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 44)
                .contentTransition(.numericText())
                .animation(Theme.quick, value: index)
            IconButton(symbol: "chevron.right", help: "The post after (Page Down)", size: 22) { store.turnPage(by: 1) }
                .opacity(index < count - 1 ? 1 : 0.35)
                .allowsHitTesting(index < count - 1)
        }
    }
}

/// A layer of a stack's post that keeps something of its own, whatever the other posts do: what,
/// and how to let it follow them again.
struct PostLayerCard: View {
    let store: DocumentStore
    let node: Node

    var body: some View {
        AspectCard(aspect: .post, title: "Only in this post", summary: Self.names(node.own ?? []),
                   accessory: AnyView(TextButton(title: "Follow the Others") { store.followDesign([node.id]) })) {
            Image(systemName: "pin")
                .font(.system(size: 11, weight: .medium))
        }
    }

    /// Properties as the inspector names them, in a list.
    static func names(_ fields: [String]) -> String {
        let words: [String: String] = [
            "frame": String(localized: "size and place"), "fill": String(localized: "fill"), "border": String(localized: "border"),
            "shadow": String(localized: "shadow"), "opacity": String(localized: "opacity"), "style": String(localized: "type"),
            "moreFills": String(localized: "fill"), "moreBorders": String(localized: "border"), "moreShadows": String(localized: "shadow"),
            "rotation": String(localized: "rotation"), "cornerRadius": String(localized: "corners"), "corners": String(localized: "corners"),
            "cornerSmoothing": String(localized: "corners"), "hidden": String(localized: "hidden"), "locked": String(localized: "locked"),
            "blur": String(localized: "blur"), "transform3D": String(localized: "depth"), "blend": String(localized: "blend"),
            "name": String(localized: "name"), "mask": String(localized: "mask"), "path": String(localized: "outline"),
            "pathBox": String(localized: "outline"), "evenOdd": String(localized: "outline"), "rising": String(localized: "direction"),
            "clips": String(localized: "clipping"), "slideSize": String(localized: "slides"),
        ]
        var seen = Set<String>()
        return fields.compactMap { words[$0] ?? $0 }.filter { seen.insert($0).inserted }.joined(separator: ", ")
    }
}
