import SwiftUI
import QuickLookThumbnailing

/// A file from another app on its way in, read away from the main thread: how far it has got,
/// the layer it is on, and the file's own picture to show meanwhile.
@MainActor @Observable
final class BringingIn {
    /// 0 to 1.
    private(set) var done: Double = 0
    private(set) var layer = ""
    private(set) var preview: CGImage?

    /// Starts making the file's picture, as the Finder shows it.
    init(_ url: URL) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 640, height: 420), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] picture, _ in
            guard let image = picture?.cgImage else { return }
            Task { @MainActor in
                withAnimation(.smooth(duration: 0.5)) { self?.preview = image }
            }
        }
    }

    /// Tells how far it has got, never going back, with the layer it is on, if it is on one.
    func advance(to fraction: Double, at layer: String) {
        guard fraction >= done else { return }
        done = min(fraction, 1)
        if !layer.isEmpty { self.layer = layer }
    }
}

/// What a tab shows while a file comes in: the file's own picture, developing as a print does,
/// pale and soft at first and sharpening as its layers are read, with a hairline of how far it
/// has got and the name of the layer it is on under it.
struct BringingInView: View {
    let progress: BringingIn

    var body: some View {
        VStack(spacing: 22) {
            if let preview = progress.preview {
                Image(decorative: preview, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 560, maxHeight: 380)
                    .saturation(0.2 + 0.8 * progress.done)
                    .blur(radius: 7 * (1 - progress.done), opaque: true)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .shadow(color: .black.opacity(0.14), radius: 22, y: 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            VStack(spacing: 9) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ink.opacity(0.08))
                    Capsule().fill(Theme.ink.opacity(0.5))
                        .frame(width: max(3, 240 * progress.done))
                }
                .frame(width: 240, height: 2)
                Text(verbatim: progress.layer)
                    .prose(11.5)
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 320)
                    .contentTransition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.45), value: progress.done)
        .animation(.smooth(duration: 0.25), value: progress.layer)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
    }
}
