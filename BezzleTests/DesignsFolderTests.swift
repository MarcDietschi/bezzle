import Testing
import AppKit
@testable import Bezzle

/// Choosing another designs folder: new designs are made there, and the designs kept until then go
/// along, each keeping its card on the home screen, or stay where they are and on the home screen.
@MainActor
struct DesignsFolderTests {
    private let tag = UUID().uuidString.prefix(6)

    private func scratch(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BezzleFolder \(name) \(UUID().uuidString.prefix(8))", isDirectory: true).standardizedFileURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func design(_ name: String, in folder: URL, layers: [Node] = []) throws -> URL {
        let url = folder.appendingPathComponent(name).appendingPathExtension(BezzleDocument.fileExtension)
        var doc = BezzleDocument()
        doc.nodes = layers
        try DesignFile.write(doc, to: url)
        return url
    }

    private func names(in folder: URL) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".\(BezzleDocument.fileExtension)") })
    }

    private func entry(_ name: String) -> Library.Entry? { Library.shared.entries.first { $0.name == name } }

    /// Runs `body` with the library in a scratch folder of its own, and a second one to choose,
    /// then puts the library back as it was and takes away what the test left.
    private func withFolders(_ body: (_ old: URL, _ new: URL) throws -> Void) rethrows {
        let library = Library.shared
        let before = library.folder
        let chosen = Library.settings.data(forKey: Library.folderKey)
        let old = scratch("old"), new = scratch("new")
        library.useForNow(old)
        defer {
            library.useForNow(before)
            if let chosen { Library.settings.set(chosen, forKey: Library.folderKey) } else { Library.settings.removeObject(forKey: Library.folderKey) }
            for folder in [old, new] {
                // Off the list of designs from elsewhere, before they go.
                for name in names(in: folder) { library.remove(folder.appendingPathComponent(name)) }
                try? FileManager.default.removeItem(at: folder)
            }
            library.refresh()
        }
        try body(old, new)
    }

    @Test func movingTakesTheDesignsAlongWithTheirCards() throws {
        try withFolders { old, new in
            let poster = try design("Poster \(tag)", in: old)
            _ = try design("Flyer \(tag)", in: old)
            // One of that name is there already.
            _ = try design("Poster \(tag)", in: new)
            Library.shared.refresh()
            let card = try #require(entry("Poster \(tag)")?.key)
            #expect(Library.shared.holds(poster))

            Library.shared.use(new, moving: true)
            #expect(Library.shared.folder == new)
            #expect(Library.settings.data(forKey: Library.folderKey) != nil)
            #expect(names(in: old).isEmpty)
            let ext = BezzleDocument.fileExtension
            #expect(names(in: new) == ["Poster \(tag).\(ext)", "Poster \(tag) 2.\(ext)", "Flyer \(tag).\(ext)"])
            // The design that came along is the same card as before, under the next name free.
            #expect(entry("Poster \(tag) 2")?.key == card)
            #expect(entry("Flyer \(tag)") != nil)
            #expect(entry("Poster \(tag)") != nil)
            #expect(!Library.shared.holds(poster))

            // New designs are made in the new folder.
            let made = try #require(Library.shared.create(artboard: CGSize(width: 100, height: 100)))
            #expect(made.deletingLastPathComponent().standardizedFileURL.path == new.path)
            #expect(Library.shared.holds(made))
        }
    }

    @Test func leavingThemKeepsThemOnTheHomeScreen() throws {
        try withFolders { old, new in
            let poster = try design("Poster \(tag)", in: old)
            Library.shared.refresh()
            Library.shared.use(new, moving: false)
            #expect(Library.shared.folder == new)
            #expect(FileManager.default.fileExists(atPath: poster.path))
            #expect(names(in: new).isEmpty)
            #expect(entry("Poster \(tag)")?.url.path == poster.path)
            // It is a design from elsewhere now: taken off the list, it stays on disk.
            #expect(!Library.shared.holds(poster))
            Library.shared.remove(poster)
            #expect(entry("Poster \(tag)") == nil)
            #expect(FileManager.default.fileExists(atPath: poster.path))
        }
    }

    @Test func theSameFolderAgainChangesNothing() throws {
        try withFolders { old, _ in
            let poster = try design("Poster \(tag)", in: old)
            Library.settings.removeObject(forKey: Library.folderKey)
            // As the Open panel may give it, with a slash at the end.
            Library.shared.use(URL(fileURLWithPath: old.path + "/"), moving: true)
            #expect(Library.shared.folder == old)
            #expect(Library.settings.data(forKey: Library.folderKey) == nil)
            #expect(FileManager.default.fileExists(atPath: poster.path))
        }
    }

    /// A design in a folder inside the designs folder is not on the home screen by the folder,
    /// so it is remembered when opened, as one from anywhere else is.
    @Test func aDesignInAFolderInsideIsRemembered() throws {
        try withFolders { old, _ in
            let inside = old.appendingPathComponent("Clients", isDirectory: true)
            try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
            let logo = try design("Logo \(tag)", in: inside)
            defer { Library.shared.remove(logo) }
            Library.shared.refresh()
            #expect(entry("Logo \(tag)") == nil)
            Library.shared.touched(logo)
            #expect(entry("Logo \(tag)") != nil)
            #expect(!Library.shared.holds(logo))
        }
    }

    /// A design open in a tab moves on with its work, and is saved where it now is.
    @Test func anOpenDesignMovesWithItsWork() throws {
        try withFolders { old, new in
            let box = Node(kind: .rectangle, name: "Box", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
            let url = try design("Card \(tag)", in: old, layers: [box])
            let store = try DocumentStore(opening: url)
            let target = new.appendingPathComponent("Card \(tag)").appendingPathExtension(BezzleDocument.fileExtension)
            #expect(store.move(to: target))
            #expect(store.url == target)
            store.save()
            DocumentStore.finishSaving()
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(try DesignFile.read(target).nodes.map(\.name) == ["Box"])
        }
    }
}
