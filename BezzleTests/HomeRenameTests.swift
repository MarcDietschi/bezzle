import Testing
import AppKit
@testable import Bezzle

/// Renaming a design from the home screen: its file is renamed beside where it is, and its card
/// stays where it was, with the new name.
@MainActor
struct HomeRenameTests {
    /// A new design is a package; an old one may still be a single file.
    private func design(_ name: String, package: Bool = true) throws -> URL {
        let url = Library.shared.folder.appendingPathComponent(name).appendingPathExtension(BezzleDocument.fileExtension)
        if package {
            try DesignFile.write(BezzleDocument(), to: url)
        } else {
            try JSONEncoder().encode(BezzleDocument()).write(to: url)
        }
        Library.shared.refresh()
        return url
    }

    private func entry(_ name: String) -> Library.Entry? { Library.shared.entries.first { $0.name == name } }

    private func clean(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
        Library.shared.refresh()
    }

    @Test(arguments: [true, false])
    func aClosedDesignIsRenamedAndKeepsItsCard(package: Bool) throws {
        let tag = UUID().uuidString.prefix(6)
        let url = try design("Poster \(tag)", package: package)
        #expect(DesignFile.isPackage(url) == package)
        let before = try #require(entry("Poster \(tag)"))
        let moved = try #require(Library.shared.rename(url, to: "  Flyer \(tag) "))
        defer { clean(url, moved) }
        #expect(moved.lastPathComponent == "Flyer \(tag).\(BezzleDocument.fileExtension)")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: moved.path))
        let after = try #require(entry("Flyer \(tag)"))
        #expect(entry("Poster \(tag)") == nil)
        // The same card, no newer than it was.
        #expect(after.key == before.key)
        #expect(after.modified == before.modified)
    }

    @Test func noNewNameChangesNothing() throws {
        let tag = UUID().uuidString.prefix(6)
        let url = try design("Card \(tag)")
        defer { clean(url) }
        #expect(Library.shared.rename(url, to: "Card \(tag)") == nil)
        #expect(Library.shared.rename(url, to: "   ") == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func onlyTheCaseChangingKeepsTheName() throws {
        let tag = UUID().uuidString.prefix(6)
        let url = try design("menu \(tag)")
        let moved = try #require(Library.shared.rename(url, to: "Menu \(tag)"))
        defer { clean(moved) }
        #expect(moved.deletingPathExtension().lastPathComponent == "Menu \(tag)")
        let names = try FileManager.default.contentsOfDirectory(atPath: Library.shared.folder.path)
        #expect(names.contains("Menu \(tag).\(BezzleDocument.fileExtension)"))
        #expect(!names.contains("menu \(tag).\(BezzleDocument.fileExtension)"))
    }

    @Test func aTakenNameGetsTheNextOneFree() throws {
        let tag = UUID().uuidString.prefix(6)
        let a = try design("A \(tag)"), b = try design("B \(tag)")
        let moved = try #require(Library.shared.rename(a, to: "B \(tag)"))
        defer { clean(a, b, moved) }
        #expect(moved.deletingPathExtension().lastPathComponent == "B \(tag) 2")
        #expect(FileManager.default.fileExists(atPath: b.path))
    }

    @Test func aSlashCannotMakeAFolder() throws {
        let tag = UUID().uuidString.prefix(6)
        let url = try design("Plan \(tag)")
        let moved = try #require(Library.shared.rename(url, to: "Plan/\(tag)"))
        defer { clean(url, moved) }
        #expect(moved.deletingLastPathComponent().standardizedFileURL == Library.shared.folder.standardizedFileURL)
        #expect(moved.deletingPathExtension().lastPathComponent == "Plan-\(tag)")
    }
}
