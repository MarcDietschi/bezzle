import SwiftUI

/// A note at the foot of the canvas after a design has been brought in from Adobe XD: how much
/// came across, and what looks a little different here, so it is clear what to check.
struct ImportReportCard: View {
    let store: DocumentStore
    let report: XDReport
    @State private var expanded = false

    private static let shown = 5

    var body: some View {
        let lines = report.notes.sorted { $0.value > $1.value }
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Brought over from Adobe XD")
                    .font(Theme.serif(17, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(verbatim: "\(count(report.artboards, "artboard")) and \(count(report.layers, "layer")).")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink3)
            }
            if lines.isEmpty && report.missingFonts.isEmpty {
                Text("Everything came across as it is.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink2)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Some things look a little different here:")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                    ForEach(Array((expanded ? lines : Array(lines.prefix(Self.shown))).enumerated()), id: \.offset) { _, line in
                        Note(text: line.key, count: line.value)
                    }
                    if !report.missingFonts.isEmpty {
                        Note(text: "Fonts not on this Mac, shown in another: " + report.missingFonts.sorted().joined(separator: ", "), count: nil)
                    }
                    if lines.count > Self.shown && !expanded {
                        TextButton(title: "\(lines.count - Self.shown) more…") { withAnimation(Theme.spring) { expanded = true } }
                    }
                }
            }
            HStack {
                Spacer()
                CardButton(title: "Done", height: 28) { withAnimation(Theme.close) { store.importReport = nil } }
            }
        }
        .padding(16)
        .frame(width: 400, alignment: .leading)
        .card(radius: 14, lifted: true)
        .padding(.bottom, 22)
    }

    private func count(_ n: Int, _ word: String) -> String {
        "\(n.formatted()) \(word)\(n == 1 ? "" : "s")"
    }
}

private struct Note: View {
    let text: String
    let count: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Theme.ink3).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0.height + 1 }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let count {
                Text(verbatim: count.formatted())
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Theme.ink3)
            }
        }
    }
}
