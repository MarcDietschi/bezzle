import Foundation
import UniformTypeIdentifiers

/// How a design is kept on disk. A design is a package: a folder the Finder shows as one file,
/// holding `document.json` and its pictures in `images`, so saving rewrites only the small
/// document. Designs made before pictures were possible are a single JSON file, and stay one.
nonisolated enum DesignFile {
    static let documentName = "document.json"
    static let imagesFolder = "images"

    /// What the Open panel offers: Bezzle's own designs, old Vellum ones too, and Adobe XD files to bring in.
    static var openableTypes: [UTType] {
        (BezzleDocument.fileExtensions + [XDImporter.fileExtension]).compactMap { UTType(filenameExtension: $0) }
    }

    static func isPackage(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    static func read(_ url: URL) throws -> BezzleDocument {
        let data = try Data(contentsOf: isPackage(url) ? url.appendingPathComponent(documentName) : url)
        return try JSONDecoder().decode(BezzleDocument.self, from: data)
    }

    /// Saves over what is there, in the form it already has; a new design becomes a package.
    static func write(_ doc: BezzleDocument, to url: URL) throws {
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
