import SwiftUI
import AppKit

/// Shares the design through iCloud, or shows who it is shared with. Nobody needs an account of
/// any kind beyond the iCloud their Mac is signed in to. Before the share sheet opens, everything
/// in the design goes up, and the button counts the pictures as they do. A design someone else
/// no longer shares can only be saved as a copy of one's own.
struct ShareButton: View {
    let store: DocumentStore
    @State private var spot = Spot()

    var body: some View {
        let sync = CloudSync.shared
        ZStack {
            if store.isReadOnly {
                CardButton(title: "Save a Copy", symbol: "doc.on.doc", height: 28) { store.saveCopy() }
                    .help("Make a design of your own from this one  ⇧⌘S")
            } else if let upload = sync.preparing[store.url] {
                Uploading(upload: upload)
                    .help("Everything in the design goes to iCloud before anyone is invited")
            } else {
                CardButton(title: store.sharing?.mark == nil ? "Share…" : "Shared", symbol: symbol(sync), height: 28) {
                    let spot = spot
                    Task { await sync.showSharing(for: store) { spot.rect } }
                }
                .help(help(sync))
            }
        }
        // Where the button is in its window, for the share sheet to come out from once the
        // design is up, however the button changed meanwhile.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { spot.rect = $0 }
        .animation(Theme.spring, value: sync.preparing[store.url])
    }

    private func symbol(_ sync: CloudSync) -> String {
        guard store.sharing?.mark != nil else { return "person.crop.circle.badge.plus" }
        if sync.problem != nil || sync.accountProblem != nil { return "exclamationmark.icloud" }
        return sync.busy ? "arrow.triangle.2.circlepath.icloud" : "person.2"
    }

    private func help(_ sync: CloudSync) -> String {
        if let problem = sync.accountProblem ?? (store.sharing != nil ? sync.problem : nil) { return problem }
        return store.sharing?.mark == nil
            ? String(localized: "Work on this design together with others, through iCloud")
            : String(localized: "Shared through iCloud: everyone’s changes come in as they are made")
    }

    /// Where the button is in its window, from the window's top left, kept out of the view's state
    /// so it is not drawn again each time it moves.
    final class Spot {
        var rect: CGRect?
    }
}

/// The Share button while the design goes up: a ring filling as the pictures do, and how many.
private struct Uploading: View {
    let upload: CloudSync.Upload

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
        .help(mark == .ended ? "Read only: this design is no longer shared with you. Save a copy to keep working on it." : "Shared through iCloud")
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}
