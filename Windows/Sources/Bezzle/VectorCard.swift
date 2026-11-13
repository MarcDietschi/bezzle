import Foundation
import WinUI
import BezzleCore

/// The Vector card, as the Mac's (Views/VectorCard.swift): a picture made shapes, while the
/// design that holds it stays open. Its dial is how much of the picture's small things the shapes
/// keep, the canvas tracing along as it turns and the design changing once it is let go; open, the
/// colours found and how many there may be, how calm the outlines run, Detail, and Picture to hold
/// to see the picture again. Pulled off (its ×, or its dial dragged on past nothing), the picture
/// is back. See WindowsCore.vectorize (Host/Vectors.swift).
extension Inspector {
    func vectorCard(_ ids: [UUID], board: Int) -> UIElement? {
        guard ids.count == 1, let v = WindowsCore.vectorLook(ids[0]) else { return nil }
        let id = ids[0]
        // Open, the colours themselves are there to see, and the line is shared with the ×.
        let shapes = Words.t("%lld shapes", v.shapes)
        let said = opened == "Vector" ? shapes : [shapes, Words.t("%lld colours", v.swatches.count)].joined(separator: " · ")
        let back: @MainActor () -> Void = { [self] in
            WindowsCore.backToPicture(id)
            session.edited(board: board)
        }
        let dial = Dial(fraction: v.detail,
                        set: { [self] f in
                            WindowsCore.setVector(id, detail: (f * 100).rounded() / 100)
                            session.changed()
                        },
                        summary: { f in Words.t("Detail") + " " + "\(Int((f * 100).rounded()))%" },
                        stops: [0.5])
        return card("Vector", said, glyph: Glyphs.vector(), dial: dial, remove: back, removal: "Back to the picture", body: { [self] in
            var rows: [UIElement] = []
            if !v.swatches.isEmpty { rows.append(swatches(v.swatches)) }
            // Auto, then so many at most (0 stands for Auto here).
            var countOptions: [(Int, String)] = [(0, "Auto")]
            for count in WindowsCore.vectorColorCounts { countOptions.append((count, String(count))) }
            let counts = Controls.segmented(v.colors ?? 0, countOptions) { [self] count in
                let most: Int? = count == 0 ? nil : count
                WindowsCore.setVector(id, colors: .some(most))
                session.changed()
            }
            try? ToolTipService.setToolTip(counts, Words.t("How many colours the shapes have at most"))
            rows.append(counts)
            // The Mac's own words for the outlines, by their keys (Italian's smooth outline is not a smooth point).
            var outlineOptions: [(Double, String)] = []
            for way in WindowsCore.vectorSmoothings { outlineOptions.append((way.value, Self.said(way.key, way.english))) }
            let outlines = Controls.segmented(v.smoothing, outlineOptions) { [self] smoothing in
                WindowsCore.setVector(id, smoothing: smoothing)
                session.changed()
            }
            try? ToolTipService.setToolTip(outlines, Words.t("How closely the outlines follow every turn of the picture"))
            rows.append(outlines)
            let detail = field(Words.t("Detail"), (v.detail * 100).rounded(), unit: "%", range: 0...100, scrub: 0.5,
                               width: Theme.cardWidth - 24 - 8 - 30) { [self] value in
                WindowsCore.setVector(id, detail: value / 100)
                session.changed()
            }
            let picture = compareButton(help: "Hold to see the picture") { [self] on in
                WindowsCore.showVectorPicture(id, on)
                session.previewed(board: board)
            }
            rows.append(Controls.line([detail, picture], spacing: 8))
            return rows
        })
    }

    /// The colours found, the most of first, as small swatches in rows (the Mac's Flow of them).
    private func swatches(_ colours: [String]) -> UIElement {
        let rows = StackPanel()
        rows.spacing = 4
        let across = Int((Theme.cardWidth - 24 + 4) / (15 + 4))
        var row: StackPanel?
        for (k, hex) in colours.prefix(36).enumerated() {
            if k % across == 0 {
                let r = StackPanel()
                r.orientation = .horizontal
                r.spacing = 4
                rows.children.append(r)
                row = r
            }
            row?.children.append(Colours.swatch(WindowsCore.Colour(hex: hex, alpha: 1), size: 15, radius: 4.5))
        }
        rows.isHitTestVisible = false
        return rows
    }

    /// Words the Mac keeps under a key of their own, in the language, or in English as the code has them.
    private static func said(_ key: String, _ english: String) -> String {
        let s = Words.t(key)
        return s == key ? english : s
    }
}
