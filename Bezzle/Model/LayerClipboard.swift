import Foundation
import CoreGraphics

/// Layers on the clipboard, as every Bezzle writes and reads them, under the type `type` (the
/// Mac's pasteboard type, the name of a registered clipboard format on Windows): the layers with
/// their frames on the canvas, the components any of them are copies of and the styles any of
/// them are named after, to come along into another design, and the design they were copied
/// from, which what is new to another design remembers (`LibraryLink`).
nonisolated struct LayerClip: Codable {
    static let type = "com.erik.bezzle.layers"

    var nodes: [Node]
    var components: [Node]?
    var styles: [Style]?
    var from: String?
}

extension BezzleDocument {
    /// What copying layers puts on the clipboard: the clip, and the words of any text layers
    /// among them as plain text, for pasting elsewhere. Nil when none of them is here.
    func clip(of ids: [UUID], designName: String?) -> (clip: LayerClip, words: String?)? {
        let nodes = ids.compactMap { id -> Node? in
            guard var n = node(id) else { return nil }
            n.frame = absoluteFrame(of: id) ?? n.frame
            return n
        }
        guard !nodes.isEmpty else { return nil }
        var used = Set(nodes.flatMap(\.componentsUsed))
        for id in used { used.formUnion(uses(id)) }
        let masters = masters.filter { used.contains($0.id) }
        let named = (nodes + masters).reduce(into: Set<UUID>()) { $0.formUnion($1.stylesUsed) }
        let styles = (styles ?? []).filter { named.contains($0.id) }
        let words = nodes.compactMap(\.text).filter { !$0.isEmpty }
        return (LayerClip(nodes: nodes, components: masters.isEmpty ? nil : masters, styles: styles.isEmpty ? nil : styles, from: designName),
                words.isEmpty ? nil : words.joined(separator: "\n"))
    }

    /// Pastes a clip's layers, made new, where they were copied from when that is in `visible`
    /// (the part of the canvas in view), else in its middle; over the originals, offset by ten so
    /// they show. Each goes onto the artboard its middle is over, or onto `focused` when it
    /// overlaps it, or the canvas. Components and styles new to this design come with them. The
    /// pasted layers' ids.
    mutating func paste(_ clip: LayerClip, designName: String?, visible: CGRect, focused: UUID?) -> [UUID] {
        var nodes = clip.nodes.map { $0.freshCopy() }
        guard let first = nodes.first else { return [] }
        let bounds = nodes.map(\.frame).reduce(first.frame) { $0.union($1) }
        var shift = CGPoint.zero
        if !visible.intersects(bounds) {
            shift = CGPoint(x: (visible.midX - bounds.midX).rounded(), y: (visible.midY - bounds.midY).rounded())
        }
        if nodes.contains(where: { n in allNodes.contains { $0.name == n.name && absoluteFrame(of: $0.id) == n.frame } }) {
            shift = shift + CGPoint(x: 10, y: 10)
        }
        for i in nodes.indices { nodes[i].frame = nodes[i].frame.offsetBy(dx: shift.x, dy: shift.y) }
        // From another design, what is new here remembers where it came from.
        let take = LibraryTake(name: clip.from == designName ? nil : clip.from, masters: clip.components ?? [], styles: clip.styles ?? [])
        let renamed = bring(take)
        if !renamed.isEmpty { nodes = nodes.map { $0.renamingStyles(renamed) } }
        for n in nodes {
            let onto = n.isArtboard ? nil : (artboard(at: n.frame.center)?.id ?? focused.flatMap { id in node(id)?.frame.intersects(n.frame) == true ? id : nil })
            attach(n, to: onto)
        }
        return nodes.map(\.id)
    }

    /// A text layer for words pasted from elsewhere, centred on `center`: as wide as its words,
    /// or for more than sixty letters, wrapping in four fifths of `width` (at most 400).
    static func pastedText(_ string: String, center: CGPoint, width: CGFloat?) -> Node {
        var node = Node(kind: .text, name: String(string.prefix(40)), frame: CGRect(origin: center, size: .zero))
        node.text = string
        node.style?.sizing = string.count > 60 ? .autoHeight : .autoWidth
        if node.style?.sizing == .autoHeight { node.frame.size.width = min(width ?? 400, 400) * 0.8 }
        node.refit()
        node.frame.origin = CGPoint(x: (center.x - node.frame.width / 2).rounded(), y: (center.y - node.frame.height / 2).rounded())
        return node
    }
}
