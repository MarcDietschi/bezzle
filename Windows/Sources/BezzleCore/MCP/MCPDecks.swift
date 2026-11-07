import Foundation

// From Bezzle/MCP/MCPDecks.swift, for Windows: what a deck is, as layers are described.

extension MCPTools {
    // MARK: Describing decks

    /// What a deck is beyond an artboard: how many posts, which is in front, what each post's text
    /// layers say, and which posts something no longer fits on.
    static func deckDetails(_ deck: Node, front: Int?, broken: Set<Int>) -> [(String, JSONValue?)] {
        let posts = deck.posts
        var texts: [(String, JSONValue)] = []
        func visit(_ n: Node) {
            if n.kind == .text {
                let words = posts.map { p -> JSONValue in
                    deck.layers(of: p).lazy.compactMap { find(n.id.mixed(Deck.key(p)), in: $0) }.first?.text.map { .string($0) } ?? .null
                }
                texts.append((n.name, .array(words)))
            }
            n.children.forEach(visit)
        }
        deck.layers(of: nil).forEach(visit)
        let cut = posts.enumerated().filter { broken.contains($0.element) }.map { JSONValue.number($0.offset + 1) }
        return [("deck", .compact([
            ("posts", .number(posts.count)),
            ("inFront", front.flatMap { posts.firstIndex(of: $0) }.map { .number($0 + 1) }),
            ("postTexts", texts.isEmpty ? nil : .object(texts)),
            ("brokenPosts", cut.isEmpty ? nil : .array(cut)),
            ("note", .string("layers lists the first post only. Every post is the same design: a change to a layer's look in any post is made in all of them, but each post's words and pictures are its own. deck with post gives one post's layers and ids.")),
        ]))]
    }

    private static func find(_ id: UUID, in n: Node) -> Node? {
        n.id == id ? n : n.children.lazy.compactMap { find(id, in: $0) }.first
    }
}
