import Testing
import AppKit
@testable import Bezzle

/// A design in a folder iCloud Drive, Google Drive or the like keep in step, open on two Macs at
/// once. To such a service the design is one item, whatever is written in it, and one written on
/// two computers at the same time is kept as two: "Poster" and "Poster 2". So a Mac only looking
/// on writes nothing in it, a copy the service made all the same is taken back into the design,
/// and a design the service has away for a moment, putting in place what another computer wrote,
/// is never begun again where it was.
@MainActor
struct CloudFolderTests {
    private func syncedFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleCloud-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        SyncedFolders.forTests[folder.path] = "iCloud Drive"
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

    private func color(of store: DocumentStore) -> RGBA? { store.doc.allNodes.first { $0.name == "R" }?.fill.color }

    private func color(at url: URL) -> RGBA? { (try? DesignFile.read(url))?.allNodes.first { $0.name == "R" }?.fill.color }

    /// Every file in the design with when it was last written, to tell whether anything was.
    private func written(_ design: URL) -> [String: Date] {
        var all: [String: Date] = [:]
        let walk = FileManager.default.enumerator(at: design, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        while let file = walk?.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            all[file.path.replacingOccurrences(of: design.path, with: "")] = values?.contentModificationDate
        }
        return all
    }

    private func look(_ store: DocumentStore) throws {
        let session = try #require(store.sharing)
        session.folder?.lookForTesting(for: session)
    }

    // MARK: Only the Mac that changes it writes

    @Test func aMacOnlyLookingOnWritesNothingInTheDesign() async throws {
        let folder = syncedFolder()
        let url = folder.appendingPathComponent("Poster.bezzle")
        try DesignFile.write(poster(), to: url)
        let anna = try open(url, as: "anna"), ben = try open(url, as: "ben")
        defer { done(folder, anna, ben) }
        #expect(anna.inSyncedFolder && ben.inSyncedFolder)
        DocumentStore.finishSaving()

        // Anna works; Ben's Mac has the design open and only looks on.
        paint(anna, .black)
        let before = written(url), saves = ben.savesAsked
        try look(ben)
        #expect(color(of: ben) == .black)
        // What reached Ben is shown, and nothing is written for it: not at once, not a moment later.
        try await Task.sleep(for: .milliseconds(900))
        DocumentStore.finishSaving()
        #expect(ben.savesAsked == saves)
        // Nor when the view is kept, nor as the design is closed with nothing done to it.
        ben.save()
        ben.save(closing: true)
        DocumentStore.finishSaving()
        #expect(written(url) == before)
        #expect(!ben.writesWhenClosed)
        // Anna, who changed it, writes it as before.
        paint(anna, .white)
        #expect(color(at: url) == .white)
        #expect(anna.writesWhenClosed)
    }

    @Test func aMacThatChangesSomethingWritesItAsBefore() throws {
        let folder = syncedFolder()
        let url = folder.appendingPathComponent("Poster.bezzle")
        try DesignFile.write(poster(), to: url)
        let anna = try open(url, as: "anna"), ben = try open(url, as: "ben")
        defer { done(folder, anna, ben) }
        paint(anna, .black)
        try look(ben)
        // Ben goes on from what Anna did: his own change is written, and reaches her.
        paint(ben, .white)
        #expect(color(at: url) == .white)
        try look(anna)
        #expect(color(of: anna) == .white)
    }

    @Test func outsideASyncedFolderWhatOthersDidIsSavedAsBefore() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleLocal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DocumentStore(url: folder.appendingPathComponent("Poster.bezzle"), document: poster())
        #expect(!store.inSyncedFolder && store.writesWhenClosed)
        var next = store.doc
        next.nodes[0].fill.color = .black
        let saves = store.savesAsked
        store.showChangesFromOthers(next)
        try await Task.sleep(for: .milliseconds(900))
        #expect(store.savesAsked == saves + 1)
    }

    // MARK: Copies the service made

    /// What iCloud Drive leaves when the design was written on two Macs at once: Ben's Mac's
    /// design, holding a change of his that Anna's has not, as "Poster 2" beside hers.
    private func copyFromTheService(_ url: URL, ben: DocumentStore, named name: String = "Poster 2.bezzle") throws -> (copy: URL, part: String) {
        let mine = FolderSync.folder(of: "ben", in: url)
        let had = Set((try? FileManager.default.contentsOfDirectory(atPath: mine.path)) ?? [])
        paint(ben, .white)
        let new = try #require(((try? FileManager.default.contentsOfDirectory(atPath: mine.path)) ?? []).first { !had.contains($0) && FolderShare.Part(fileName: $0) != nil })
        let copy = url.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: copy)
        // Anna's Mac never had it: the service kept Ben's design apart.
        try FileManager.default.removeItem(at: mine.appendingPathComponent(new))
        return (copy, new)
    }

    @Test func aCopyTheServiceMadeIsTakenIntoTheDesignAndPutAway() throws {
        let folder = syncedFolder()
        let url = folder.appendingPathComponent("Poster.bezzle")
        try DesignFile.write(poster(), to: url)
        let anna = try open(url, as: "anna"), ben = try open(url, as: "ben")
        defer { done(folder, anna, ben) }
        paint(anna, .black)
        let (copy, part) = try copyFromTheService(url, ben: ben)
        try look(anna)
        #expect(color(of: anna) == .black)

        #expect(FolderSync.copiesFromTheService(of: url).map(\.lastPathComponent) == ["Poster 2.bezzle"])
        let bin = folder.appendingPathComponent("Bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let folded = FolderSync.foldCopies(beside: url, open: []) { try FileManager.default.moveItem(at: $0, to: bin.appendingPathComponent($0.lastPathComponent)) }
        #expect(folded)
        // The copy is gone from beside the design, kept where things put away go.
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(FileManager.default.fileExists(atPath: bin.appendingPathComponent("Poster 2.bezzle").path))
        // Ben's change is the design's again, and Anna's Mac shows it.
        #expect(FileManager.default.fileExists(atPath: FolderSync.folder(of: "ben", in: url).appendingPathComponent(part).path))
        try look(anna)
        #expect(color(of: anna) == .white)
        #expect(FolderSync.copiesFromTheService(of: url).isEmpty)
    }

    @Test func iCloudsAndGoogleDrivesNamesAreKnownAndAnOpenCopyIsLeftAsItIs() throws {
        let folder = syncedFolder()
        let url = folder.appendingPathComponent("Poster.bezzle")
        try DesignFile.write(poster(), to: url)
        let anna = try open(url, as: "anna"), ben = try open(url, as: "ben")
        defer { done(folder, anna, ben) }
        let (copy, _) = try copyFromTheService(url, ben: ben, named: "Poster (1).bezzle")
        #expect(FolderSync.copiesFromTheService(of: url).map(\.lastPathComponent) == ["Poster (1).bezzle"])
        // Open here, it is someone's to look at: left until it is closed.
        #expect(!FolderSync.foldCopies(beside: url, open: [copy.standardizedFileURL.path]) { _ in Issue.record("Put away while open") })
        #expect(FileManager.default.fileExists(atPath: copy.path))
    }

    @Test func copiesThatAreNotTheServicesAreLeftAsTheyAre() throws {
        let folder = syncedFolder()
        let url = folder.appendingPathComponent("Poster.bezzle")
        try DesignFile.write(poster(), to: url)
        let anna = try open(url, as: "anna"), ben = try open(url, as: "ben")
        defer { done(folder, anna, ben) }
        paint(anna, .black)
        // A copy made in the Finder and named "Poster 2", never opened: older than the design,
        // it brings nothing, and is someone's copy.
        try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent("Poster 2.bezzle"))
        paint(anna, .white)
        #expect(FolderSync.copiesFromTheService(of: url).isEmpty)
        // One named as the Finder names its copies, though it brings something.
        _ = try copyFromTheService(url, ben: ben, named: "Poster copy.bezzle")
        #expect(FolderSync.copiesFromTheService(of: url).isEmpty)
        // One of another design whose name begins the same way.
        var other = poster()
        other.nodes[0].name = "Other"
        try DesignFile.write(other, to: folder.appendingPathComponent("Poster 3.bezzle"))
        #expect(FolderSync.copiesFromTheService(of: url).isEmpty)
        // And in a folder no service keeps in step, nothing is a copy of the service's.
        SyncedFolders.forTests[folder.path] = nil
        #expect(FolderSync.copiesFromTheService(of: url).isEmpty)
        SyncedFolders.forTests[folder.path] = "iCloud Drive"
    }

    // MARK: Away for a moment

    @Test func aDesignAwayForAMomentIsNotBegunAgainWhereItWas() async throws {
        let folder = syncedFolder()
        let url = folder.appendingPathComponent("Poster.bezzle")
        try DesignFile.write(poster(), to: url)
        let anna = try open(url, as: "anna")
        defer { done(folder, anna) }
        anna.missingGrace = 2
        // The service takes the design away to put another computer's in place, a new item.
        let away = folder.appendingPathComponent("Held", isDirectory: true)
        try FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: away.appendingPathComponent("Poster.bezzle"))
        try FileManager.default.removeItem(at: url)
        paint(anna, .black)
        try await Task.sleep(for: .milliseconds(300))
        DocumentStore.finishSaving()
        // Not begun again meanwhile, which the service would keep as a second design.
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // Back, it is written into as soon as it is looked for again.
        try FileManager.default.copyItem(at: away.appendingPathComponent("Poster.bezzle"), to: url)
        for _ in 0..<40 where color(at: url) != .black {
            try await Task.sleep(for: .milliseconds(100))
            DocumentStore.finishSaving()
        }
        #expect(color(at: url) == .black)
    }

    @Test func aDesignThatStaysAwayIsWrittenAgainWhereItWasSoNothingIsLost() async throws {
        let folder = syncedFolder()
        let url = folder.appendingPathComponent("Poster.bezzle")
        try DesignFile.write(poster(), to: url)
        let anna = try open(url, as: "anna")
        defer { done(folder, anna) }
        anna.missingGrace = 0.6
        try FileManager.default.removeItem(at: url)
        paint(anna, .black)
        for _ in 0..<40 where color(at: url) != .black {
            try await Task.sleep(for: .milliseconds(100))
            DocumentStore.finishSaving()
        }
        #expect(color(at: url) == .black)
    }
}
