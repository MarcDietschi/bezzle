import SwiftUI

/// Texts along a curve, as a card (see `TextCurve`).
///
/// Bent, the dial bends them, from a dip through straight to a ring, the picks are the bends worth
/// having, and pulled off the card they are straight again. Riding a shape, the dial slides them
/// round its outline, the arrows send them to its other side, and pulled off, they come off it.
struct CurveCard: View {
    let store: DocumentStore
    let nodes: [Node]
    var live = false

    /// The bends offered, by how much of a circle the words go round.
    static let bends: [(value: Double, name: LocalizedStringResource)] = [
        (-0.25, LocalizedStringResource("curve.dip", defaultValue: "Dip", comment: "A bend of text that sags down in the middle.")),
        (0.25, LocalizedStringResource("curve.arch", defaultValue: "Arch", comment: "A bend of text that arches up in the middle.")),
        (0.5, LocalizedStringResource("curve.half", defaultValue: "Half circle", comment: "Text bent round half a circle.")),
        (1, LocalizedStringResource("curve.ring", defaultValue: "Ring", comment: "Text bent all the way round into a circle.")),
    ]

    var body: some View {
        if let first = nodes.first {
            if nodes.allSatisfy(\.rides) { riding(first) } else { bent(first) }
        }
    }

    // MARK: Bent

    private func bent(_ first: Node) -> some View {
        let bend = first.curve?.bend ?? 0
        let same = nodes.allSatisfy { abs(($0.curve?.bend ?? 0) - bend) < 0.0005 }
        let dial = Dial(value: bend * 100, range: -100...100, stops: [-100, -50, 0, 50, 100], step: 5, action: DocumentStore.bending) { v in
            store.bendSelection((v * 10).rounded() / 1000)
        }
        return AspectCard(aspect: .curve, title: LocalizedStringResource("curve.title", defaultValue: "Curve", comment: "Inspector card: text bent into an arc."),
                          summary: same ? Self.summary(bend) : SelectionInspector.several, dial: dial,
                          remove: { store.straightenSelection() }, removal: "Straighten", live: live) {
            CurveGlyph(bend: bend)
        } picks: {
            HStack(spacing: 8) {
                PresetStrip(action: DocumentStore.bending, items: Self.bends.map { b in
                    PresetItem(id: "curve-\(Int(b.value * 100))", name: b.name, active: nodes.allSatisfy { abs(($0.curve?.bend ?? 0) - b.value) < 0.0005 }) {
                        $0.bend(to: b.value)
                    }
                }) { item in
                    CurveGlyph(bend: Self.bends.first { "curve-\(Int($0.value * 100))" == item.id }?.value ?? 0)
                }
                NumberField(label: "", value: same ? (bend * 360).rounded() : nil, unit: "°", range: -360...360, step: 15, scrub: 1, decimals: 0,
                            action: DocumentStore.bending) { v in
                    store.bendSelection(v / 360)
                }
                .frame(width: Inspector.endField)
            }
        } exact: {
            EmptyView()
        }
    }

    /// How far round a circle the words go, in degrees, or a ring.
    static func summary(_ bend: Double) -> String {
        if abs(abs(bend) - 1) < 0.0005 { return String(localized: LocalizedStringResource("curve.ring", defaultValue: "Ring")) }
        let degrees = Int((abs(bend) * 360).rounded())
        return bend < 0 ? "−\(degrees)°" : "\(degrees)°"
    }

    // MARK: Riding a shape

    private func riding(_ first: Node) -> some View {
        let shape = store.doc.parent(of: first.id)?.carrier
        let at = Self.at(of: first)
        let dial = Dial(value: at * 100, range: 0...100, stops: [0, 25, 50, 75, 100], step: 1, action: DocumentStore.slidingText) { v in
            store.updateSelection(DocumentStore.slidingText) { n in
                guard n.rides else { return }
                n.curve?.at = (v * 100).rounded() / 10_000
            }
        }
        return AspectCard(aspect: .curve, title: LocalizedStringResource("curve.on-path", defaultValue: "On Path", comment: "Inspector card: text running along a shape's outline."),
                          summary: nodes.count == 1 ? shape?.name ?? "" : SelectionInspector.several, dial: dial,
                          remove: { store.straightenSelection() }, removal: "Take off path", live: live,
                          accessory: AnyView(IconButton(symbol: "arrow.up.arrow.down", help: "To the other side", size: 22) { store.flipSelectedCurves() })) {
            RidingGlyph()
        } picks: {
            EmptyView()
        } exact: {
            EmptyView()
        }
    }

    static func at(of node: Node) -> Double { CurvedText.at(of: node) }
}

/// A line of letters, bent as far as the words are: short strokes along an arc, as a line of
/// type is drawn small.
struct CurveGlyph: View {
    var bend: Double
    var size: CGFloat = 15

    var body: some View {
        Canvas { ctx, s in
            let theta = min(abs(bend), 1) * 2 * .pi
            var arc = Path()
            if theta < 0.05 {
                arc.move(to: CGPoint(x: 0, y: 0))
                arc.addLine(to: CGPoint(x: 1, y: 0))
            } else {
                let up: Double = bend > 0 ? 1 : -1
                let steps = 48
                for i in 0...steps {
                    let phi = -theta / 2 + theta * Double(i) / Double(steps)
                    let p = CGPoint(x: sin(phi), y: -up * cos(phi))
                    if i == 0 { arc.move(to: p) } else { arc.addLine(to: p) }
                }
            }
            let box = arc.boundingRect
            let line: CGFloat = 2.3
            let room = CGRect(origin: .zero, size: s).insetBy(dx: line / 2 + 0.4, dy: line / 2 + 0.4)
            let k = min(room.width / max(box.width, 0.001), box.height > 0.001 ? room.height / box.height : .greatestFiniteMagnitude)
            let t = CGAffineTransform(translationX: -box.midX, y: -box.midY).concatenating(CGAffineTransform(scaleX: k, y: k))
                .concatenating(CGAffineTransform(translationX: room.midX, y: room.midY))
            ctx.stroke(arc.applying(t), with: .foreground, style: StrokeStyle(lineWidth: line, lineCap: .butt, lineJoin: .round, dash: [1.9, 1.1]))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A shape's outline with a line of letters lying along its top: words riding a shape.
struct RidingGlyph: View {
    var size: CGFloat = 15

    var body: some View {
        Canvas { ctx, s in
            let r = CGRect(origin: .zero, size: s).insetBy(dx: 4, dy: 4).offsetBy(dx: 0, dy: 1.6)
            ctx.stroke(Path(ellipseIn: r), with: .foreground, lineWidth: 1)
            let c = CGPoint(x: r.midX, y: r.midY), radius = r.width / 2 + 1.9
            let words = Path { p in
                p.addArc(center: c, radius: radius, startAngle: .degrees(-165), endAngle: .degrees(-15), clockwise: false)
            }
            ctx.stroke(words, with: .foreground, style: StrokeStyle(lineWidth: 2.1, lineCap: .butt, dash: [1.8, 1.1]))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension SelectionInspector {
    /// Bending texts that are straight, offered first among what they could gain.
    func curveOffer(_ nodes: [Node], kinds: Set<Node.Kind>) -> [AddBar.Item] {
        guard kinds == [.text], !nodes.contains(where: { $0.curve != nil || $0.locked }) else { return [] }
        return [AddBar.Item(id: "add-curve", aspect: .curve, title: LocalizedStringResource("curve.title", defaultValue: "Curve"),
                            help: "Bend the text", action: DocumentStore.bending) { $0.bend(to: 0.25) }]
    }
}
