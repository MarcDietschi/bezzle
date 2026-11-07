import Foundation
import AppKit

// From Bezzle/MCP/MCPInspect.swift, for Windows (see MCPStore.swift).

/// The design as someone building it reads it, for the assistant: a layer's box and the room round
/// it, its looks by value and by the names the design gives them, its type, and the layer as code,
/// as the Inspect mode shows them. See `Inspect`.
extension MCPTools {
    func inspectDefinitions(design: (String, JSONValue)) -> [Definition] {
        func text(_ d: String) -> JSONValue { ["type": "string", "description": .string(d)] }
        return [
            Definition(name: "inspect", title: "Inspect a layer",
                       description: """
                       What building a layer needs, as Bezzle's Inspect mode shows it: its box on its screen and in what holds it, \
                       how far it lies inside that on each side (or the distances to another layer, with to), its fills, borders, \
                       corners, shadows, opacity, blend and blur by value and by the name of the design's style where it has one \
                       (the tokens design_tokens writes), its type for words, the component and variant it is a copy of, and the \
                       layer as CSS and as SwiftUI using those tokens. Distances are in points, between the upright boxes layers \
                       are drawn in.
                       """,
                       properties: .object([
                           design,
                           ("layer", text("The layer or screen, by id or name; the one selected otherwise.")),
                           ("to", text("Another layer or screen to measure the distances to, by id or name.")),
                           ("format", .object([("type", "string"), ("enum", ["css", "swiftui", "both"]),
                                               ("description", "Which code: css, swiftui, or both (the default).")])),
                       ]), readOnly: true, run: { [unowned self] in try await self.inspect($0) }),
        ]
    }

    func inspect(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let seen = store.seenDoc
        let id: UUID
        if let ref = try args.string("layer") {
            id = try Self.layer(ref, in: seen)
        } else {
            guard let first = store.selection.first else { throw MCPError("Nothing is selected: say which layer, by id or name.") }
            id = first
        }
        guard let node = seen.node(id), let box = Inspect.box(of: id, in: seen) else { throw MCPError("There is no such layer to inspect.") }
        let format = try args.string("format")?.lowercased() ?? "both"
        guard ["css", "swiftui", "both"].contains(format) else { throw MCPError("format is css, swiftui or both.") }
        let tokens = Inspect.Tokens(seen)
        func n(_ v: CGFloat) -> JSONValue { .number(Double(Inspect.number(v)) ?? Double(v)) }
        func rect(_ r: CGRect) -> JSONValue { ["x": n(r.minX), "y": n(r.minY), "width": n(r.width), "height": n(r.height)] }
        func token(_ id: UUID?) -> JSONValue? {
            tokens[id].map { t in ["name": .string(t.name), "css": .string(t.css), "swiftui": .string(t.swift)] }
        }
        func colour(_ c: RGBA) -> JSONValue { .string(Inspect.hex(c)) }

        let screen = node.isArtboard ? nil : seen.artboard(of: id)
        let parent = node.isArtboard ? nil : seen.parent(of: id)
        let onScreen = screen.map { box.offsetBy(dx: -$0.frame.minX, dy: -$0.frame.minY) }
        let parentBox = parent.flatMap { Inspect.box(of: $0.id, in: seen) }
        let insets = parentBox.map { Inspect.Insets(of: box, in: $0) }

        var distances: JSONValue?
        if let ref = try args.string("to") {
            let other = try Self.layer(ref, in: seen)
            guard let b = Inspect.box(of: other, in: seen) else { throw MCPError("There is no such layer to measure to.") }
            distances = .array(Inspect.spans(from: box, to: b).map { s in
                .compact([
                    ("length", n(s.length)),
                    ("direction", .string(s.across ? "horizontal" : "vertical")),
                    ("from", ["x": n(s.from.x), "y": n(s.from.y)]),
                    ("to", ["x": n(s.to.x), "y": n(s.to.y)]),
                ])
            })
        }

        let style = node.style
        let component = Inspect.component(of: id, in: seen)
        let fills: [JSONValue] = node.fills.map { f in
            .compact([
                ("color", f.gradient == nil && f.image == nil ? colour(f.color) : nil),
                ("gradient", f.gradient.flatMap { $0.stops.isEmpty ? nil : .string(DesignTokens.cssGradient($0)) }),
                ("image", f.image.map { .string($0.asset) }),
                ("token", token(f.named)),
            ])
        }
        let json: JSONValue = .compact([
            ("id", .string(node.id.uuidString)),
            ("name", .string(node.name)),
            ("kind", .string(node.isCopy ? "component" : node.kind.rawValue)),
            ("path", .array(Inspect.path(of: id, in: seen).map { .string($0.name) })),
            ("component", component.map { c in
                .compact([("name", .string(c.master.name)), ("variant", .string(c.variant)), ("state", c.state.map { .string($0.rawValue) }),
                          ("copy", c.copy.id == id ? nil : .string(c.copy.id.uuidString))])
            }),
            ("size", ["width": n(node.isArtboard || node.rotation == 0 ? box.width : node.frame.width),
                      "height": n(node.isArtboard || node.rotation == 0 ? box.height : node.frame.height)]),
            ("onScreen", onScreen.map(rect)),
            ("screen", screen.map { .string($0.name) }),
            ("in", parent.map { p in .compact([("id", .string(p.id.uuidString)), ("name", .string(p.name))]) }),
            ("insets", insets.map { i in ["top": n(i.top), "right": n(i.right), "bottom": n(i.bottom), "left": n(i.left)] }),
            ("distances", distances),
            ("rotation", abs(node.rotation) > 0.01 ? n(CGFloat(node.rotation)) : nil),
            ("opacity", node.opacity < 0.999 ? .number(node.opacity) : nil),
            ("blend", node.blend.map { .string($0.rawValue) }),
            ("blur", node.blur.flatMap { b in b.on ? .compact([("radius", n(b.radius)), ("behind", b.background ? true : nil)]) : nil }),
            ("fills", node.kind == .text ? nil : .array(fills)),
            ("borders", .array(node.borders.map { b in
                .compact([("width", n(b.width)), ("position", .string(b.position.rawValue)), ("color", colour(b.color)),
                          ("dash", b.dash > 0 ? n(b.dash) : nil), ("token", token(b.named))])
            })),
            ("corners", node.kind == .rectangle || node.isArtboard
                ? (node.radii.contains { $0 > 0 } ? .compact([("radii", .array(node.radii.map(n))), ("token", token(node.cornersNamed))]) : nil)
                : nil),
            ("shadows", .array(node.shadows.map { s in
                .compact([("x", n(s.x)), ("y", n(s.y)), ("blur", n(s.blur)), ("spread", s.spread.map(n)), ("color", colour(s.color)),
                          ("inside", s.inset == true ? true : nil), ("token", token(s.named))])
            })),
            ("text", node.kind == .text ? style.map { t in
                .compact([
                    ("words", .string(node.text ?? "")),
                    ("family", .string(t.family == TextStyle.system ? "system" : t.family)),
                    ("face", .string(t.face)),
                    ("weight", .number(DesignTokens.weight(t.face))),
                    ("size", n(t.size)),
                    ("lineHeight", t.lineSpacing.map(n)),
                    ("letterSpacing", t.tracking != 0 ? n(Inspect.tracking(t)) : nil),
                    ("align", .string(t.align.rawValue)),
                    ("case", t.letterCase.map { .string($0.rawValue) }),
                    ("color", node.fills.first.map { colour($0.color) }),
                    ("colorToken", token(node.fills.first?.named)),
                    ("token", token(t.named)),
                ])
            } : nil),
            ("css", format != "swiftui" ? .string(Inspect.css(node, in: seen, tokens: tokens)) : nil),
            ("swiftui", format != "css" ? .string(Inspect.swiftUI(node, in: seen, tokens: tokens)) : nil),
        ])
        return [.text(json.text)]
    }
}
