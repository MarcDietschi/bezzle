import SwiftUI
import AppKit

/// Shares the design through iCloud, or shows who it is shared with. Nobody needs an account of
/// any kind beyond the iCloud their Mac is signed in to.
struct ShareButton: View {
    let store: DocumentStore
    @State private var anchor = Anchor()

    var body: some View {
        let sync = CloudSync.shared
        CardButton(title: store.sharing == nil ? "Share…" : "Shared", symbol: symbol(sync), height: 28) {
            guard let view = anchor.view else { return }
            Task { await sync.showSharing(for: store, from: view) }
        }
        .background(AnchorView(anchor: anchor))
        .help(help(sync))
    }

    private func symbol(_ sync: CloudSync) -> String {
        guard store.sharing != nil else { return "person.crop.circle.badge.plus" }
        if sync.problem != nil || sync.accountProblem != nil { return "exclamationmark.icloud" }
        return sync.busy ? "arrow.triangle.2.circlepath.icloud" : "person.2"
    }

    private func help(_ sync: CloudSync) -> String {
        if let problem = sync.accountProblem ?? (store.sharing != nil ? sync.problem : nil) { return problem }
        return store.sharing == nil
            ? "Work on this design together with others, through iCloud"
            : "Shared through iCloud: everyone’s changes come in as they are made"
    }

    /// Where the share sheet comes out from.
    final class Anchor {
        weak var view: NSView?
    }

    private struct AnchorView: NSViewRepresentable {
        let anchor: Anchor
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            anchor.view = view
            return view
        }
        func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
    }
}
