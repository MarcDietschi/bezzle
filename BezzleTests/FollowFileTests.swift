import Testing
import AppKit
@testable import Bezzle

/// A design open while its file is renamed or moved, in the Finder or by someone else in a synced
/// folder, goes on where the file now is and never begins again under its old name, which would
/// leave everyone working on one or the other. Someone else's design, shared by link, keeps the
/// name it was shared under.
@MainActor
struct FollowFileTests {
    private func syncedFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleDrive-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        SyncedFolders.forTests[folder.path] = "Google Drive"
        return folder
    }

    private func done(_ folder: URL, _ stores: DocumentStore...) {
        for store in stores { store.sharing?.close() }
        SyncedFolders.forTests[folder.path] = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func poster() -> BezzleDocument {
        var doc = BezzleDocument()
        doc.nodes = [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50))]
        return doc
    }

    /// The design at `url` open on the Mac with `replica`, as everyone's files in it have it.
    private func open(_ url: URL, as replica: String) throws -> DocumentStore {
        let session = try #require(Collaboration.open(url, replica: replica))
        let store = DocumentStore(url: url, document: session.document())
        store.sharing = session
        session.attach(to: store)
        return store
    }

    private func paint(_ store: DocumentStore, _ color: RGBA) {
        guard let id = store.doc.allNodes.first(where: { $0.name == "R" })?.id else { Issue.record("No layer R"); return }
        store.edit("Colour") { doc in doc.update(id) { $0.fill.color = color } }
        store.save()
        DocumentStore.finishSaving()
    }

    private func color(at url: URL) -> RGBA? {
        (try? DesignFile.read(url))?.allNodes.first { $0.name == "R" }?.fill.color
    }

    @Test func aDesignRenamedOnAnotherMacGoesOnWhereItIsNow() throws {
        let folder = syncedFolder()
        let old = folder.appendingPathComponent("Poster.bezzle"), new = folder.appendingPathComponent("Flyer.bezzle")
        try DesignFile.write(poster(), to: old)
        let anna = try open(old, as: "anna"), ben = try open(old, as: "ben")
        defer { done(folder, anna, ben) }

        // Ben renames it; the folder carries the new name to Anna's Mac, where it is open too.
        ben.rename(to: "Flyer")
        #expect(ben.url.path == new.path)
        paint(anna, .black)
        #expect(anna.url.path == new.path)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(color(at: new) == .black)
        // What Anna does reaches Ben, in the one design.
        let session = try #require(ben.sharing)
        session.folder?.lookForTesting(for: session)
        #expect(ben.doc.allNodes.first { $0.name == "R" }?.fill.color == .black)
    }

    @Test func oneTheFolderBringsAsANewFileIsFoundByItsRoom() throws {
        let folder = syncedFolder()
        let old = folder.appendingPathComponent("Poster.bezzle"), new = folder.appendingPathComponent("Poster (Ben).bezzle")
        try DesignFile.write(poster(), to: old)
        let anna = try open(old, as: "anna")
        defer { done(folder, anna) }
        // Not renamed in place: a new file under the new name, and the old one gone, so the
        // bookmark leads nowhere.
        try FileManager.default.copyItem(at: old, to: new)
        try FileManager.default.removeItem(at: old)
        paint(anna, .black)
        #expect(anna.url.path == new.path)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(color(at: new) == .black)
    }

    @Test func renamedInTheMomentOfASaveItIsSavedWhereItWent() async throws {
        let folder = syncedFolder()
        let old = folder.appendingPathComponent("Poster.bezzle"), new = folder.appendingPathComponent("Flyer.bezzle")
        try DesignFile.write(poster(), to: old)
        let anna = try open(old, as: "anna")
        defer { done(folder, anna) }
        let id = try #require(anna.doc.allNodes.first { $0.name == "R" }?.id)
        // The save is asked for while the file is still there, and written once it went.
        let gate = DispatchSemaphore(value: 0)
        DocumentStore.saving.async { gate.wait() }
        anna.edit("Colour") { doc in doc.update(id) { $0.fill.color = .black } }
        anna.save()
        try FileManager.default.moveItem(at: old, to: new)
        gate.signal()
        DocumentStore.finishSaving()
        try await Task.sleep(for: .milliseconds(200))
        DocumentStore.finishSaving()
        #expect(anna.url.path == new.path)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(color(at: new) == .black)
        // Its own changes too are in the design's files, for the others.
        let names = try FileManager.default.contentsOfDirectory(atPath: FolderSync.folder(of: "anna", in: new).path)
        #expect(FolderShare.parts(files: names).contains { $0.kind == .changes })
    }

    @Test func aDesignRenamedInTheFinderGoesOnUnderItsNewName() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleFinder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appendingPathComponent("Poster.bezzle"), new = folder.appendingPathComponent("Flyer.bezzle")
        try DesignFile.write(poster(), to: old)
        let store = try DocumentStore(opening: old)
        #expect(store.sharing == nil)
        try FileManager.default.moveItem(at: old, to: new)
        // As when Bezzle comes to the front again.
        #expect(store.follow())
        #expect(store.name == "Flyer")
        paint(store, .black)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(color(at: new) == .black)
    }

    @Test func oneNowhereToBeFoundIsWrittenAgainWhereItWas() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleGone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Poster.bezzle")
        try DesignFile.write(poster(), to: url)
        let store = try DocumentStore(opening: url)
        try FileManager.default.removeItem(at: url)
        #expect(!store.follow())
        // Nothing done to it is lost.
        paint(store, .black)
        #expect(store.url.path == url.path)
        #expect(color(at: url) == .black)
    }

    @Test func nothingWrittenIntoAPackageBringsItBack() throws {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleNone-\(UUID().uuidString).bezzle")
        #expect(throws: DesignFile.Gone.self) { try DesignFile.write(BezzleDocument(), to: gone, creating: false) }
        #expect(throws: DesignFile.Gone.self) { try DesignFile.makeFolder(gone.appendingPathComponent("versions"), in: gone) }
        #expect(throws: DesignFile.Gone.self) { try VersionFiles.write(Data([1]), as: UUID(), to: gone) }
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    // MARK: Renaming someone else's design

    @Test func whatMayBeRenamed() {
        #expect(SharingMark.shared.renamable)
        #expect(SharingMark.inFolder("Google Drive").renamable)
        #expect(!SharingMark.sharedBy("Anna").renamable)
        #expect(!SharingMark.sharedBy(nil).renamable)
        #expect(!SharingMark.ended.renamable)
    }

    @Test func aDesignSharedWithYouKeepsItsName() throws {
        let url = Library.shared.folder.appendingPathComponent("Shared \(UUID().uuidString.prefix(6))").appendingPathExtension(BezzleDocument.fileExtension)
        try DesignFile.write(poster(), to: url)
        try SharingFiles.write(ShareLink(secret: ShareKeys.newSecret().base64URL, title: "Poster", ownerName: "Anna"), to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            Library.shared.refresh()
        }
        #expect(Library.mark(of: url) == .sharedBy("Anna"))
        #expect(Library.shared.rename(url, to: "Mine now") == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let store = try DocumentStore(opening: url)
        defer { store.sharing?.close() }
        #expect(!store.mayRename)
        store.rename(to: "Mine now")
        #expect(store.url == url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
