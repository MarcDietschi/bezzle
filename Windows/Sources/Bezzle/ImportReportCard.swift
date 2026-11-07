import Foundation
import WinUI
import UWP
import BezzleCore

/// A note at the foot of the canvas after a design has been brought in from another app, as the
/// Mac's ImportReportCard: how much came across, and what looks a little different here, so it is
/// clear what to check. 400 wide, radius 14, lifted; Done puts it away.
@MainActor
final class ImportReportCard {
    let root = Grid()
    private let card = Theme.card(radius: 14)
    private let shadow = Image()
    private let summary: WindowsCore.ImportSummary
    private var expanded = false
    private static let shown = 5

    init(_ summary: WindowsCore.ImportSummary) {
        self.summary = summary
        root.width = 400
        root.horizontalAlignment = .center
        root.verticalAlignment = .bottom
        root.margin = Theme.inset(0, 0, 0, 22 + 9)
        shadow.isHitTestVisible = false
        shadow.stretch = .fill
        root.children.append(shadow)
        root.children.append(card)
        // A press on the card goes no further: the canvas under it is not clicked.
        card.pointerPressed.addHandler { _, args in args?.handled = true }
        root.sizeChanged.addHandler { [weak self] _, _ in self?.drawShadow() }
        fill()
    }

    private func fill() {
        let stack = StackPanel()
        stack.spacing = 10
        stack.padding = Theme.inset(16)

        let heading = StackPanel()
        heading.spacing = 3
        heading.children.append(Theme.text(Words.t("Brought over from %@", summary.source), size: 17, weight: 500, serif: true))
        // Each count is a phrase of its own, so each can be singular or plural.
        let counts = Words.t("%@ and %@.", Words.t("%lld artboards", summary.artboards), Words.t("%lld layers", summary.layers))
        heading.children.append(Theme.text(counts, size: 12, ink: 3))
        stack.children.append(heading)

        if summary.notes.isEmpty && summary.missingFonts.isEmpty {
            stack.children.append(Theme.text(Words.t("Everything came across as it is."), size: 12.5, ink: 2))
        } else {
            let list = StackPanel()
            list.spacing = 5
            list.children.append(Theme.text(Words.t("Some things look a little different here:"), size: 12.5, weight: 500, ink: 2))
            for note in expanded ? summary.notes : Array(summary.notes.prefix(Self.shown)) {
                list.children.append(line(note.text, count: note.count))
            }
            if !summary.missingFonts.isEmpty {
                list.children.append(line(Words.t("Fonts not on this computer, shown in another: %@", summary.missingFonts.joined(separator: ", ")), count: nil))
            }
            if summary.notes.count > Self.shown && !expanded {
                let more = ExportSheet.textButton(Words.t("%lld more…", summary.notes.count - Self.shown)) { [weak self] in
                    guard let self else { return }
                    self.expanded = true
                    self.fill()
                }
                if let more = more as? FrameworkElement { more.horizontalAlignment = .left }
                list.children.append(more)
            }
            stack.children.append(list)
        }

        let done = Controls.cardButton(Words.t("Done"), height: 28) { [weak self] in self?.root.visibility = .collapsed }
        done.horizontalAlignment = .right
        stack.children.append(done)
        card.child = stack
    }

    /// One thing that came across differently: a dot, its words, wrapped, and how often.
    private func line(_ text: String, count: Int?) -> UIElement {
        let row = Grid()
        for width in [GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star), GridLength(value: 1, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = width
            row.columnDefinitions.append(column)
        }
        row.columnSpacing = 8
        let dot = Border()
        dot.width = 4
        dot.height = 4
        dot.cornerRadius = Theme.corners(2)
        dot.background = Theme.ink(3)
        dot.verticalAlignment = .top
        dot.margin = Theme.inset(0, 7, 0, 0)
        row.children.append(dot)
        let words = Theme.text(text, size: 12, ink: 2)
        words.textWrapping = .wrap
        words.textTrimming = .none
        words.lineHeight = 12 * 1.45
        words.verticalAlignment = .top
        try? Grid.setColumn(words, 1)
        row.children.append(words)
        if let count {
            let number = Theme.text(count.formatted(), size: 11.5, ink: 3)
            number.verticalAlignment = .top
            number.margin = Theme.inset(4, 1, 0, 0)
            try? Grid.setColumn(number, 2)
            row.children.append(number)
        }
        return row
    }

    /// The Mac's lifted card: the shadow colour at 16%, blur 18, 9 down.
    private func drawShadow() {
        let scale = Double(root.xamlRoot?.rasterizationScale ?? 1)
        let w = root.actualWidth, h = root.actualHeight
        guard w > 0, h > 0 else { return }
        let pad = Int((40 * scale).rounded())
        let sw = Int((w * scale).rounded()), sh = Int((h * scale).rounded())
        var bitmap: WriteableBitmap?
        _ = WindowsCore.softShadow(width: sw, height: sh, pad: pad, blur: 18 * scale, dy: 0, colour: Theme.shadow, alpha: 0.16) { bw, bh in
            bitmap = WriteableBitmap(Int32(bw), Int32(bh))
            return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        try? bitmap?.invalidate()
        shadow.source = bitmap
        shadow.width = w + 2 * Double(pad) / scale
        shadow.height = h + 2 * Double(pad) / scale
        shadow.margin = Theme.inset(-Double(pad) / scale, -Double(pad) / scale + 9, -Double(pad) / scale, -Double(pad) / scale - 9)
    }
}
