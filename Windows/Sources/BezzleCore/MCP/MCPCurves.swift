import Foundation
import AppKit

// From Bezzle/MCP/MCPCurves.swift, for Windows (see MCPStore.swift).

/// Words along curves for the assistant: bending texts into arcs, laying them along a shape's
/// outline, sliding them round it, and straightening them again. See `TextCurve`.
extension MCPTools {
    func curveDefinitions(design: (String, JSONValue)) -> [Definition] {
        func text(_ d: String) -> JSONValue { ["type": "string", "description": .string(d)] }
        func number(_ d: String) -> JSONValue { ["type": "number", "description": .string(d)] }
        func boolean(_ d: String) -> JSONValue { ["type": "boolean", "description": .string(d)] }
        func list(_ d: String) -> JSONValue { ["type": "array", "items": ["type": "string"], "description": .string(d)] }
        let layers = ("layers", list("Text layers by id, or by name (\"Artboard/Name\" when the name is on several). Leave it out for the selection."))
        return [
            Definition(name: "curve_text", title: "Curve text",
                       description: "Runs texts' letters along a curve, as one line. Give bend to bend each into an arc of its own: the degrees of a circle its words go round, from -360 to 360; above zero they arch up, below they sag, at 360 they close into a ring, and 0 straightens them. The middle of the words stays where it is. Or give shape to lay each along a rectangle's, ellipse's, path's or line's outline: the text and the shape become a group (or the text joins the group the shape already carries words in), and the words follow the shape wherever it is moved, turned or reshaped. They stand on its outline reading upright, at the top of a closed shape, or from the start, middle or end of an open one as the text is aligned; at moves them along, reversed runs them the other way round (upright along the bottom of a ring, inside it), hang has their tops on the outline instead of their feet. Texts already riding a shape take at, reversed and hang without shape. describe_layers shows \"curve\" on such texts.",
                       properties: .object([
                           design, layers,
                           ("bend", number("Degrees of a circle the words go round, -360…360; 0 is straight.")),
                           ("shape", text("The rectangle, ellipse, path or line to lay the words along, by id or name.")),
                           ("at", number("Where along the outline, 0…1 in its own direction: where the words begin, their middle or end as they are aligned; their middle on a closed shape.")),
                           ("reversed", boolean("Run against the outline's direction, as words along the bottom of a ring do.")),
                           ("hang", boolean("Letters hang from the outline, their tops on it, rather than stand on it.")),
                       ]), run: { [unowned self] in try await self.curveText($0) }),
            Definition(name: "straighten_text", title: "Straighten text",
                       description: "Makes texts on a curve straight again, where the middle of their words was. Texts riding a shape come off it, out of its group, reading upright; a group left with its shape alone is the shape again.",
                       properties: .object([design, layers]), run: { [unowned self] in try await self.straightenText($0) }),
        ]
    }

    func curveText(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        let doc = store.doc
        let texts = ids.compactMap { doc.node($0) }
        guard !texts.isEmpty, texts.allSatisfy({ $0.kind == .text }) else { throw MCPError("Give text layers.") }
        let locked = texts.filter(\.locked).map(\.name)
        guard locked.isEmpty else { throw MCPError("\(locked.joined(separator: ", ")) \(locked.count == 1 ? "is" : "are") locked. Unlock it with update_layers first.") }
        let bend = try args.number("bend")
        let shapeID = try args.string("shape").map { try Self.layer($0, in: doc) }
        let at = try args.number("at"), reversed = try args.bool("reversed"), hang = try args.bool("hang")
        if bend != nil, shapeID != nil { throw MCPError("Give bend or shape, not both.") }
        if let at, !(0...1).contains(at) { throw MCPError("at goes from 0 to 1.") }
        if let bend {
            guard (-360...360).contains(bend) else { throw MCPError("bend goes from -360 to 360 degrees.") }
            try change(store, bend == 0 ? DocumentStore.straightening : DocumentStore.bending) { doc in
                for id in ids {
                    if bend == 0, doc.node(id)?.rides == true {
                        DocumentStore.takeOffPath([id], in: &doc)
                    } else if doc.node(id)?.rides != true {
                        doc.update(id) { $0.bend(to: bend / 360) }
                    } else {
                        throw MCPError("\(doc.node(id)?.name ?? "A text") rides a shape. straighten_text takes it off first.")
                    }
                }
            }
            return described(ids, in: store, full: true)
        }
        if let shape = shapeID {
            guard let node = doc.node(shape), TextCurve.canCarry(node) else {
                throw MCPError("Words can ride a rectangle, an ellipse, a path or a line lying flat.")
            }
            for id in ids where !DocumentStore.canRide(id, on: shape, in: doc) {
                throw MCPError("\(doc.node(id)?.name ?? "A text") cannot ride \(node.name): neither may be locked, in a repeat grid, or the shape of a mask.")
            }
            var curve = TextCurve(rides: true)
            curve.at = at
            curve.reversed = reversed == true ? true : nil
            curve.hangs = hang == true ? true : nil
            try change(store, DocumentStore.riding) { doc in
                for id in ids { DocumentStore.ride(id, on: shape, curve: curve, in: &doc) }
            }
            store.selection = ids.filter { store.doc.node($0) != nil }
            return described(ids, in: store, full: true)
        }
        // Along the shape they ride already.
        guard texts.allSatisfy(\.rides) else { throw MCPError("Give bend, or a shape to lay the words along.") }
        guard at != nil || reversed != nil || hang != nil else { throw MCPError("Give at, reversed or hang to move them along their shape.") }
        try change(store, DocumentStore.slidingText) { doc in
            for id in ids {
                doc.update(id) { n in
                    if let at { n.curve?.at = at }
                    if let reversed { n.curve?.reversed = reversed ? true : nil }
                    if let hang { n.curve?.hangs = hang ? true : nil }
                    n.refit()
                }
            }
        }
        return described(ids, in: store, full: true)
    }

    func straightenText(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store).filter { store.doc.node($0)?.curve != nil }
        guard !ids.isEmpty else { throw MCPError("None of those texts runs along a curve.") }
        try change(store, DocumentStore.straightening) { doc in
            DocumentStore.takeOffPath(ids, in: &doc)
            for id in ids { doc.update(id) { $0.straighten() } }
        }
        return described(ids, in: store, full: true)
    }

    /// How a text runs along a curve, for describe_layers.
    static func curveDetails(_ node: Node, in doc: BezzleDocument) -> [(String, JSONValue?)] {
        guard node.kind == .text, let curve = node.curve else { return [] }
        if let bend = curve.bend { return [("curve", .object([("bend", .number(Double((bend * 360 * 10).rounded() / 10)))]))] }
        var pairs: [(String, JSONValue?)] = []
        if curve.rides == true, let shape = doc.parent(of: node.id)?.carrier { pairs.append(("shape", .string(shape.id.uuidString))) }
        pairs.append(("at", .number((CurvedText.at(of: node) * 1000).rounded() / 1000)))
        if curve.reversed == true { pairs.append(("reversed", true)) }
        if curve.hangs == true { pairs.append(("hang", true)) }
        return [("curve", .compact(pairs))]
    }
}
