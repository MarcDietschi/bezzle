import SwiftUI
import AppKit

/// Shares the design by link, or shows that it is shared. Nobody needs an account of any kind:
/// anyone with the link can work on the design, from Bezzle on a Mac or in a browser. Before the
/// link is copied, everything in the design goes to the relay, and the button counts the pictures
/// as they do. Whoever shared the design can stop sharing it; a design someone else no longer
/// shares can only be saved as a copy of one's own.
struct ShareButton: View {
    let store: DocumentStore
    @Environment(MenuHost.self) private var menus
    /// A moment after the link went to the pasteboard, for the button to show it did.
    @State private var copied = false
    private static let menuID = "share"

    var body: some View {
        let sharing = Sharing.shared
        ZStack {
            if store.isReadOnly {
                CardButton(title: "Save a Copy", symbol: "doc.on.doc", height: 28) { store.saveCopy() }
                    .help("Make a design of your own from this one  ⇧⌘S")
            } else if let upload = sharing.preparing[store.url] {
                Uploading(upload: upload)
                    .help("Everything in the design goes up before the link is copied")
            } else {
                CardButton(title: store.sharing?.mark == nil ? "Share…" : "Shared", symbol: copied ? "checkmark" : symbol, height: 28) {
                    menus.toggle(Self.menuID, width: 260, entries: entries)
                }
                .menuAnchor(Self.menuID)
                .help(copied ? Text("The link is copied: paste it into any mail or chat") : help)
            }
        }
        .animation(Theme.spring, value: sharing.preparing[store.url])
    }

    private var entries: [MenuEntry] {
        var out: [MenuEntry] = [
            .item("Copy Link") {
                Task {
                    guard await Sharing.shared.copyLink(for: store) else { return }
                    copied = true
                    try? await Task.sleep(for: .seconds(2.5))
                    copied = false
                }
            },
            .note("Anyone with the link can work on the design."),
        ]
        if store.sharing?.mark == .shared {
            out += [.separator, .item("Stop Sharing…") { confirmStop() }]
        }
        return out
    }

    private func confirmStop() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Stop sharing “\(store.name)”?")
        alert.informativeText = String(localized: "The link stops working. Everyone who has the design keeps it as it is now, read only.")
        alert.addButton(withTitle: String(localized: "Stop Sharing"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let stop = { (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            Task { _ = await Sharing.shared.stopSharing(store) }
        }
        if let window = store.canvas?.window { alert.beginSheetModal(for: window, completionHandler: stop) } else { stop(alert.runModal()) }
    }

    private var problem: String? { store.sharing?.cloud?.problem }

    private var symbol: String {
        guard store.sharing?.mark != nil else { return "person.crop.circle.badge.plus" }
        return problem != nil ? "exclamationmark.triangle" : "person.2"
    }

    private var help: Text {
        if let problem { return Text(problem) }
        guard let mark = store.sharing?.mark else { return Text("Work on this design together with others, by link") }
        return Text(mark.help)
    }
}

/// The Share button while the design goes up: a ring filling as the pictures do, and how many.
private struct Uploading: View {
    let upload: Sharing.Upload

    var body: some View {
        HStack(spacing: 7) {
            ProgressRing(fraction: upload.total > 0 ? Double(upload.done) / Double(upload.total) : nil)
                .frame(width: 11, height: 11)
            Text(upload.total > 0 ? "Uploading \(upload.done) of \(upload.total)" : "Preparing…")
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.ink2)
                .contentTransition(.numericText(value: Double(upload.done)))
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .card(radius: 28 * 0.28)
        .fixedSize()
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

/// A ring drawn in pencil as far as `fraction` goes, or a short arc going round while it is not known.
struct ProgressRing: View {
    let fraction: Double?
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(Theme.ink4, lineWidth: 1.6)
            Circle()
                .trim(from: 0, to: fraction.map { max(0.04, $0) } ?? 0.28)
                .stroke(Theme.pencil, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(-90 + (fraction == nil && turning ? 360 : 0)))
                .animation(fraction == nil ? .linear(duration: 0.9).repeatForever(autoreverses: false) : Theme.spring, value: turning)
                .animation(Theme.spring, value: fraction)
        }
        .onAppear { turning = true }
    }
}

/// How the design is shared, beside its name in the top bar.
struct SharingTag: View {
    let mark: SharingMark

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: mark == .ended ? "lock.fill" : "person.2.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(mark.title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(mark == .ended ? Theme.ink3 : Theme.pencil)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(mark == .ended ? Theme.ink.opacity(0.06) : Theme.pencilWash))
        .help(Text(mark.help))
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}
