import Foundation

// Web pages brought in on Windows as the Mac brings them in (WebCapture.swift, WebImporter.swift):
// what the window and the command-line tools ask of the core.

/// From Store/WebImportOperations.swift: why pages cannot be brought into a design.
enum WebBringing: LocalizedError {
    case readOnly

    var errorDescription: String? {
        switch self {
        case .readOnly: String(localized: "This design can only be looked at, so nothing can be brought into it.")
        }
    }
}

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

    /// Brings the page at `url` into the open design `slot`, beside its artboards, as the Mac's
    /// sheet does with Into set to the design open: an artboard a width, one step of its undo
    /// history. Says which they are and what came across.
    public static func importWebsite(_ url: URL, widths: [WebWidth], hideBanners: Bool = true, into slot: Slot,
                                     progress: ((String, Double) -> Void)? = nil) async throws -> (ids: [UUID], summary: ImportSummary) {
        start()
        let (ids, report) = try await WebImport.run(url, sizes: widths.map(\.size), hideBanners: hideBanners, into: slot, progress: progress)
        return (ids, summary(of: report))
    }

    /// From Store/WebImportOperations.swift: pages read from the web brought into the design the
    /// core works on, beside what is in it rather than as a design of their own. Each an
    /// artboard, laid in a row to the right of everything on the canvas, level with the top of
    /// what is there, a page's pictures copied into the design. One step of the undo history.
    /// Says which they are (the window selects them) and what was only approximated.
    static func bringIn(_ reads: [WebRead], held: [String: Data], source: String) throws -> (ids: [UUID], report: ImportReport) {
        guard !isReadOnly, let doc = design else { throw WebBringing.readOnly }
        let (made, report) = WebConverter.document(reads, source: source)
        guard !made.nodes.isEmpty else { throw WebCapture.Failure.empty }
        try keep(held)
        let boards = WebImport.placed(made.nodes, beside: doc.nodes)
        edit { doc in
            for board in boards { doc.attach(board, to: nil) }
        }
        let ids = boards.map(\.id).filter { design?.node($0) != nil }
        return (ids, report)
    }

    /// Writes pictures into the design's own images, where they are not yet, and gives them to
    /// Skia. A design kept as a single file becomes a package first.
    private static func keep(_ pictures: [String: Data]) throws {
        guard !pictures.isEmpty, let url = designURL else { return }
        try makePackage()
        let images = url.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        for (name, data) in pictures.sorted(by: { $0.key < $1.key }) {
            let file = images.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: file.path) { try data.write(to: file, options: .atomic) }
            giveSkia(name, data)
        }
    }

    /// Told why a website's WebGL canvas stays a picture, for the person who works on Bezzle (the
    /// app sends it to its trace, as the Mac logs it).
    public static var webImportLog: (String) -> Void {
        get { WebCapture.log }
        set { WebCapture.log = newValue }
    }

    /// What came across, as the window and the AI server say it.
    static func summary(of report: ImportReport) -> ImportSummary {
        let notes = report.notes.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { (text: $0.key, count: $0.value) }
        return ImportSummary(source: report.source, artboards: report.artboards, layers: report.layers, notes: notes,
                             missingFonts: report.missingFonts.sorted())
    }
}
