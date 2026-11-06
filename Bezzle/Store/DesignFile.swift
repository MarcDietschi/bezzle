import Foundation
import UniformTypeIdentifiers

/// How a design is kept on disk. A design is a package: a folder the Finder shows as one file,
/// holding `document.json` and its pictures in `images`, so saving rewrites only the small
/// document. Designs made before pictures were possible are a single JSON file, and stay one.
nonisolated enum DesignFile {
    static let documentName = "document.json"
    static let imagesFolder = "images"

    /// What the Open panel offers: Bezzle's own designs, old Vellum ones too, and files from other apps to bring in.
    static var openableTypes: [UTType] {
        BezzleDocument.fileExtensions.compactMap { UTType(filenameExtension: $0) } + importableTypes
    }

    /// Adobe XD, Figma and Sketch files. Each is a single file even where its app also knows a
    /// package of the same name, as Sketch did once.
    static var importableTypes: [UTType] {
        Importer.fileExtensions.compactMap { UTType(filenameExtension: $0, conformingTo: .data) }
    }

    static func isPackage(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// Whether the design is where `url` says: its package with the design in it, or its file.
    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: isPackage(url) ? url.appendingPathComponent(documentName).path : url.path)
    }

    /// The design that was at `url` is not there now; see `write(_:to:creating:)`.
    struct Gone: Error {}

    /// Makes a folder in the package of a design that is there, never the package itself: a
    /// design renamed or moved away while open, as by someone else in a synced folder, must not
    /// begin again where it was, with everyone working on one or the other.
    static func makeFolder(_ folder: URL, in design: URL) throws {
        guard isPackage(design) else { throw Gone() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    static func read(_ url: URL) throws -> BezzleDocument {
        let data = try Data(contentsOf: isPackage(url) ? url.appendingPathComponent(documentName) : url)
        var doc = try JSONDecoder().decode(BezzleDocument.self, from: data)
        // Every layer named after a style looks as it does, however the file was last written.
        doc.repairStyles()
        return doc
    }

    /// Turns a design kept as a single file into a package, as everything since pictures is.
    static func makePackage(_ url: URL) throws {
        guard !isPackage(url) else { return }
        let doc = try read(url)
        let old = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: old)
        do {
            try write(doc, to: url)
            try? FileManager.default.removeItem(at: old)
        } catch {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.moveItem(at: old, to: url)
            throw error
        }
    }

    /// Saves over what is there, in the form it already has; a new design becomes a package.
    /// Not `creating`, a design that is not there throws `Gone` instead, as for an open design
    /// whose file went while it was being saved.
    static func write(_ doc: BezzleDocument, to url: URL, creating: Bool = true) throws {
        if !creating, !exists(url) { throw Gone() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(doc)
        if isPackage(url) {
            try data.write(to: url.appendingPathComponent(documentName), options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        } else {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(imagesFolder, isDirectory: true), withIntermediateDirectories: true)
            try data.write(to: url.appendingPathComponent(documentName), options: .atomic)
        }
    }
}
