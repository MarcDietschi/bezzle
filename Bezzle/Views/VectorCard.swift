import SwiftUI

/// A picture made shapes, as a card, while the design that holds it stays open: how much of the
/// picture's small things the shapes keep, turned by a drag across the card, with the canvas
/// tracing along; the colours found, and how many there may be; how calm the outlines run.
/// Pulled off, the picture is back. See `DocumentStore.vectorize`.
struct VectorCard: View {
    let store: DocumentStore
    let group: Node

    var body: some View {
        let id = group.id
        let settings = store.vectorSettings(of: id) ?? VectorSettings()
        let counts = store.vectorCounts(of: id) ?? (0, [])
        // Open, the colours themselves are there to see, and the line is shared with the ×.
        let shapes = String(localized: "\(counts.shapes) shapes")
        let said = store.openAspect == .vector ? shapes : [shapes, String(localized: "\(counts.colors.count) colours")].joined(separator: " · ")
        AspectCard(aspect: .vector, title: "Vector", summary: said,
                   dial: Dial(value: settings.detail * 100, range: 0...100, stops: [50], step: 5, action: "Change Vector") { v in
                       store.setVector(id) { $0.detail = v.rounded() / 100 }
                   },
                   remove: { store.backToPicture(id) }, removal: "Back to the picture", live: store.vectorWanted[id] != nil) {
            VectorGlyph()
        } picks: {
            if !counts.colors.isEmpty {
                Flow(spacing: 4) {
                    ForEach(Array(counts.colors.prefix(36).enumerated()), id: \.offset) { _, color in
                        Swatch(color: color, radius: 4.5)
                            .frame(width: 15, height: 15)
                    }
                }
                .accessibilityHidden(true)
            }
            SegmentedWell(selection: Binding(get: { settings.colors }, set: { count in
                store.setVector(id) { $0.colors = count }
            }), options: [(nil, "Auto")] + VectorSettings.colorCounts.map { (Optional($0), .verbatim("\($0)")) })
                .help("How many colours the shapes have at most")
            SegmentedWell(selection: Binding(get: { settings.nearestSmoothing }, set: { smoothing in
                store.setVector(id) { $0.smoothing = smoothing }
            }), options: VectorSettings.smoothings.map { ($0.value, $0.title) })
                .help("How closely the outlines follow every turn of the picture")
            HStack(spacing: 8) {
                NumberField(label: "Detail", value: (settings.detail * 100).rounded(), unit: "%", range: 0...100, step: 5, scrub: 0.5, decimals: 0,
                            action: "Change Vector") { v in
                    store.setVector(id) { $0.detail = v / 100 }
                }
                CompareButton(help: "Hold to see the picture", label: "Picture") { store.showVectorPicture(id, $0) }
            }
        }
    }
}

/// A curve between two points, the handle of one drawn out: a path.
struct VectorGlyph: View {
    var size: CGFloat = 14

    var body: some View {
        Canvas { ctx, s in
            let a = CGPoint(x: 2.2, y: s.height - 2.6), b = CGPoint(x: s.width - 2.2, y: 3.2)
            let handle = CGPoint(x: s.width * 0.36, y: 1.6)
            var curve = Path()
            curve.move(to: a)
            curve.addCurve(to: b, control1: CGPoint(x: a.x + 0.5, y: s.height * 0.3), control2: handle)
            ctx.stroke(curve, with: .foreground, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            var arm = Path()
            arm.move(to: b)
            arm.addLine(to: handle)
            ctx.stroke(arm, with: .foreground, style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: handle.x - 1.3, y: handle.y - 1.3, width: 2.6, height: 2.6)), with: .foreground)
            for p in [a, b] {
                ctx.fill(Path(CGRect(x: p.x - 1.8, y: p.y - 1.8, width: 3.6, height: 3.6)), with: .foreground)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension SelectionInspector {
    /// Vectorize, offered to layers filled with a picture.
    func vectorOffer(_ nodes: [Node]) -> [AddBar.Item] {
        guard !store.isReadOnly, store.vectorizing.isEmpty, !nodes.isEmpty, nodes.allSatisfy({ store.vectorizable($0.id) }) else { return [] }
        return [AddBar.Item(id: "add-vector", aspect: .vector, title: DocumentStore.vectorizing, help: "Trace the picture into shapes",
                            action: DocumentStore.vectorizing, change: { _ in }, add: { store.vectorize() })]
    }
}
