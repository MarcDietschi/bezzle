import Foundation

// Web pages brought in on Windows as the Mac brings them in (WebCapture.swift, WebImporter.swift):
// what the window and the command-line tools ask of the core.

extension WindowsCore {
    /// A width a page is read at, as the Mac's Import from a Website sheet offers them.
    public enum WebWidth: Hashable, Sendable {
        case desktop, tablet, mobile
        /// A width of its own, from 240 up.
        case custom(Double)

        /// How wide it is read, in CSS pixels.
        public var width: Double { Double(size.width) }

        var size: WebCapture.Size {
            switch self {
            case .desktop: .desktop
            case .tablet: .tablet
            case .mobile: .mobile
            case .custom(let w): .custom(CGFloat(w))
            }
        }

        /// The widths as the Mac's AI tool takes them: the offered sizes by their widths.
        public init(_ width: Double) {
            switch Int(width.rounded()) {
            case Int(WebCapture.Size.desktop.width): self = .desktop
            case Int(WebCapture.Size.tablet.width): self = .tablet
            case Int(WebCapture.Size.mobile.width): self = .mobile
            default: self = .custom(width)
            }
        }
    }

    /// The address of what was typed, when it is a web page or a file Bezzle can read.
    public static func webAddress(_ typed: String) -> URL? { WebCapture.address(typed) }

    /// The sizes chosen, the widest first, each width once, as the Mac's sheet reads them.
    public static func webWidths(_ chosen: [WebWidth]) -> [WebWidth] {
        chosen.sorted { $0.width > $1.width }.reduce(into: []) { list, s in if !list.contains(where: { $0.width == s.width }) { list.append(s) } }
    }

    /// Brings the page at `url` in as a new design in `folder`, read at each width (1440 alone when
    /// none): an artboard each, side by side, as on the Mac. `progress` hears what it is doing and
    /// how much is done (0…1). Cancelling the task stops it.
    public static func importWebsite(_ url: URL, widths: [WebWidth], hideBanners: Bool = true, into folder: URL,
                                     progress: ((String, Double) -> Void)? = nil) async throws -> (URL, ImportSummary) {
        start()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Library.shared.folder = folder
        let (made, report) = try await WebImport.run(url, sizes: widths.map(\.size), hideBanners: hideBanners, into: folder, progress: progress)
        return (made, summary(of: report))
    }

    /// What came across, as the window and the AI server say it.
    static func summary(of report: ImportReport) -> ImportSummary {
        let notes = report.notes.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { (text: $0.key, count: $0.value) }
        return ImportSummary(source: report.source, artboards: report.artboards, layers: report.layers, notes: notes,
                             missingFonts: report.missingFonts.sorted())
    }
}
