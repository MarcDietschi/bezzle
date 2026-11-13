import Foundation

/// Web pages brought into a design that is open, beside what is in it, rather than as a design
/// of their own: the screens of a web app read one after another, signed in and clicked through
/// in Bezzle's browser (`WebBrowser`), gathered in one design.
extension DocumentStore {
    /// Brings pages read from the web in: each an artboard, laid in a row to the right of
    /// everything on the canvas, level with the top of what is there, a page's pictures copied
    /// into the design. One step of the undo history, and the new artboards selected. Says which
    /// they are and what was only approximated.
    @discardableResult
    func bringIn(_ reads: [WebRead], held: [String: Data], source: String) throws -> (ids: [UUID], report: ImportReport) {
        guard !isReadOnly else { throw WebBringing.readOnly }
        let (made, report) = WebConverter.document(reads, source: source)
        guard !made.nodes.isEmpty else { throw WebCapture.Failure.empty }
        try keep(held)
        let boards = WebImport.placed(made.nodes, beside: doc.nodes)
        editApart("Import from a Website") { doc in
            for board in boards { doc.attach(board, to: nil) }
        }
        let ids = boards.map(\.id).filter { doc.node($0) != nil }
        selection = ids
        if !report.lines.isEmpty { importReport = report }
        return (ids, report)
    }

    /// Writes pictures into the design's own images, where they are not yet. A design kept as
    /// a single file becomes a package first.
    private func keep(_ pictures: [String: Data]) throws {
        guard !pictures.isEmpty else { return }
        if !DesignFile.isPackage(url) {
            save()
            Self.finishSaving()
            try DesignFile.makePackage(url)
            becamePackage()
        }
        let images = url.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
        try DesignFile.makeFolder(images, in: url)
        let fm = FileManager.default
        for (name, data) in pictures.sorted(by: { $0.key < $1.key }) {
            let file = images.appendingPathComponent(name)
            guard !fm.fileExists(atPath: file.path) else { continue }
            try data.write(to: file, options: .atomic)
            assets.arrived(name)
        }
    }
}

enum WebBringing: LocalizedError {
    case readOnly

    var errorDescription: String? {
        switch self {
        case .readOnly: String(localized: "This design can only be looked at, so nothing can be brought into it.")
        }
    }
}
