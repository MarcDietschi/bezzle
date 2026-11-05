import Testing
import AppKit
@testable import Bezzle

/// How a shared design's changes are kept in parts nobody else writes (`FolderShare`), the keys
/// its room is sealed with (`ShareKeys`), and two Macs with one design open in a synced folder.
@MainActor
struct FolderShareTests {
    private typealias Part = FolderShare.Part

    private func design(_ nodes: [Node]) -> BezzleDocument {
        var doc = BezzleDocument()
        doc.nodes = nodes
        return doc
    }

    // MARK: Parts

    @Test func partsAreNamedSoTheySortAsTheirTimes() throws {
        let part = Part(.changes, upTo: 1_762_358_400_123)
        #expect(part.fileName == "c-001762358400123.lzfse")
        #expect(part.record(of: "anna") == "c.anna.001762358400123")
        #expect(Part(fileName: part.fileName) == part)
        let record = try #require(Part.record("w.anna.001762358400123"))
        #expect(record.replica == "anna" && record.part == Part(.whole, upTo: 1_762_358_400_123))
        // Times beyond what a 32-bit Int holds, as the browser's Bezzle has.
        #expect(Part(fileName: "w-999999999999999.lzfse")?.upTo == 999_999_999_999_999)
        for name in ["c-1762358400123.lzfse", "x-001762358400123.lzfse", "c-00176235840012a.lzfse", "c-001762358400123.json",
                     "c-001762358400123 (1).lzfse", "me.json", ".c-001762358400123.lzfse"] {
            #expect(Part(fileName: name) == nil, "\(name)")
        }
        for key in ["c.Anna.001762358400123", "c.anna.1762358400123", "c.anna", "c..001762358400123", "c.\(String(repeating: "a", count: 33)).001762358400123"] {
            #expect(Part.record(key) == nil, "\(key)")
        }
        #expect([Part(.whole, upTo: 5), Part(.changes, upTo: 5), Part(.changes, upTo: 3)].sorted()
            == [Part(.changes, upTo: 3), Part(.changes, upTo: 5), Part(.whole, upTo: 5)])
    }

    @Test func theRoomsRecordsAreKnownByTheirKeys() {
        let id = UUID()
        let records: [ShareRecord] = [.meta, .person("anna"), .part("anna", Part(.changes, upTo: 42)),
                                      .picture(String(repeating: "ab", count: 32)), .version(id), .versionDesign(id)]
        for record in records { #expect(ShareRecord(key: record.key) == record, "\(record.key)") }
        for key in ["m.", "m.Anna", "p.ABAB", "p.\(String(repeating: "AB", count: 32))", "v.nope", "x.anna", "metadata"] {
            #expect(ShareRecord(key: key) == nil, "\(key)")
        }
    }

    @Test func aCopysNewestWholeAndTheChangesAfterItAreRead() {
        let parts = [Part(.whole, upTo: 10), Part(.changes, upTo: 12), Part(.changes, upTo: 15), Part(.whole, upTo: 15), Part(.changes, upTo: 20)]
        // Coming new: the newest whole, and what came after it.
        #expect(FolderShare.toRead(parts, read: []) == [Part(.whole, upTo: 15), Part(.changes, upTo: 20)])
        // Following all along: every change was read, so the whole holds nothing new.
        #expect(FolderShare.toRead(parts, read: [Part(.whole, upTo: 10), Part(.changes, upTo: 12), Part(.changes, upTo: 15)])
            == [Part(.changes, upTo: 20)])
        // A change not read yet, but still there: read on its own.
        #expect(FolderShare.toRead(parts, read: [Part(.whole, upTo: 10), Part(.changes, upTo: 15)]) == [Part(.changes, upTo: 12), Part(.changes, upTo: 20)])
        // Away while the copy folded twice, what went before is only in its newest whole.
        #expect(FolderShare.toRead(parts, read: [Part(.changes, upTo: 5)]) == [Part(.whole, upTo: 15), Part(.changes, upTo: 20)])
        // A whole that will not open: the one before it, and every change after that.
        #expect(FolderShare.toRead(parts, read: [], failed: [Part(.whole, upTo: 15)])
            == [Part(.whole, upTo: 10), Part(.changes, upTo: 12), Part(.changes, upTo: 15), Part(.changes, upTo: 20)])
        #expect(FolderShare.toRead(parts, read: Set(parts)).isEmpty)
    }

    @Test func foldingKeepsTheWholeBeforeAndDeletesWhatCameBeforeIt() {
        var parts = [Part(.whole, upTo: 1)] + (2...24).map { Part(.changes, upTo: Int64($0)) }
        #expect(!FolderShare.shouldFold(parts))
        parts.append(Part(.changes, upTo: 25))
        #expect(FolderShare.shouldFold(parts))
        parts.append(Part(.whole, upTo: 25))
        // The first fold: nothing before the whole before it.
        #expect(FolderShare.folded(parts, into: 25).isEmpty)
        parts += (26...49).map { Part(.changes, upTo: Int64($0)) } + [Part(.whole, upTo: 49)]
        let gone = FolderShare.folded(parts, into: 49)
        #expect(Set(gone) == Set(parts.filter { $0.upTo < 25 }))
        let left = parts.filter { !gone.contains($0) }
        #expect(left.filter { $0.kind == .whole } == [Part(.whole, upTo: 25), Part(.whole, upTo: 49)])
        #expect(FolderShare.nextUpTo(10, after: left) == 50)
        #expect(FolderShare.nextUpTo(100, after: left) == 100)
    }

    @Test func twoMacsStartingFromTheSameFileMakeTheSameDesign() throws {
        let doc = design([CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50))])
        let a = FolderShare.first(doc, modified: 1_000, by: "anna"), b = FolderShare.first(doc, modified: 1_000, by: "ben")
        var merged = a
        merged.merge(b)
        #expect(merged.flatDesign().document().nodes == doc.nodes)
        #expect(FolderShare.unpack(try #require(FolderShare.pack(merged))) == merged)
    }

    // MARK: Keys

    @Test func everyKeyOfARoomComesFromItsSecret() throws {
        let secret = Data((0..<32).map { UInt8($0) })
        let keys = try #require(ShareKeys(secret: secret))
        let again = try #require(ShareKeys(link: secret.base64URL))
        #expect(keys.room == again.room && keys.readToken == again.readToken && keys.writeToken == again.writeToken)
        #expect(keys.room.count == 64 && keys.room.allSatisfy(\.isHexDigit))
        #expect(Set([keys.room, keys.readToken, keys.writeToken]).count == 3)
        #expect(keys.pictureName("a.png") == again.pictureName("a.png"))
        #expect(keys.pictureName("a.png") != keys.pictureName("b.png"))
        #expect(keys.pictureName("a.png").count == 64)
        #expect(ShareKeys(secret: Data(count: 31)) == nil)
        #expect(ShareKeys(link: "not a secret!") == nil)
        #expect(Data(base64URL: secret.base64URL) == secret)
        #expect(Data(hex: secret.hex) == secret)
    }

    @Test func whatIsSealedOpensOnlyForTheRoomAndWhatItIsAbout() throws {
        let secret = ShareKeys.newSecret()
        let mine = try #require(ShareKeys(secret: secret)), theirs = try #require(ShareKeys(secret: secret))
        let plain = Data("a change".utf8)
        let sealed = try #require(mine.seal(plain, about: "c.anna.000000000000001"))
        #expect(sealed.first == 0x02)
        #expect(theirs.open(sealed, about: "c.anna.000000000000001") == plain)
        #expect(mine.open(sealed, about: "c.anna.000000000000002") == nil)
        #expect(ShareKeys(secret: ShareKeys.newSecret())!.open(sealed, about: "c.anna.000000000000001") == nil)
        var tampered = sealed
        tampered[tampered.count - 3] ^= 1
        #expect(theirs.open(tampered, about: "c.anna.000000000000001") == nil)
        // Each copy seals with its own salt, so the same words never look the same twice.
        #expect(try #require(theirs.seal(plain, about: "x")).dropFirst().prefix(16) != sealed.dropFirst().prefix(16))
    }

    // MARK: Two Macs in a synced folder

    private func syncedFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleDrive-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        SyncedFolders.forTests[folder.path] = "Google Drive"
        return folder
    }

    private func done(_ folder: URL) {
        SyncedFolders.forTests[folder.path] = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func edit(_ session: Collaboration, _ name: String, _ change: (inout Node) -> Void) {
        var doc = session.state.flatDesign().document()
        guard let id = doc.allNodes.first(where: { $0.name == name })?.id else { Issue.record("No layer \(name)"); return }
        doc.update(id, change)
        session.takeIn(doc)
        session.persist()
        DocumentStore.finishSaving()
    }

    private func layer(_ session: Collaboration, _ name: String) -> Node? {
        session.state.flatDesign().document().allNodes.first { $0.name == name }
    }

    @Test func twoMacsWithOneDesignOpenInAFolderKeepEachOthersChanges() throws {
        let folder = syncedFolder()
        defer { done(folder) }
        let url = folder.appendingPathComponent("Poster.bezzle")
        try DesignFile.write(design([CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50)),
                                                    CanvasTests.rect("S", CGRect(x: 100, y: 10, width: 50, height: 50))]), to: url)
        let anna = try #require(Collaboration.open(url, replica: "anna"))
        let ben = try #require(Collaboration.open(url, replica: "ben"))
        #expect(layer(ben, "R") != nil)

        // At once, each in their own files: the same layer, different properties, and another layer.
        edit(anna, "R") { $0.frame.origin.x = 300 }
        edit(ben, "R") { $0.fill.color = .black }
        edit(ben, "S") { $0.name = "S, renamed" }
        anna.folder?.lookForTesting(for: anna)
        ben.folder?.lookForTesting(for: ben)
        for session in [anna, ben] {
            #expect(layer(session, "R")?.frame.minX == 300)
            #expect(layer(session, "R")?.fill.color == .black)
            #expect(layer(session, "S, renamed") != nil)
        }
        #expect(anna.state == ben.state)
        // Nobody ever wrote in the other's folder.
        for (who, other) in [("anna", "ben"), ("ben", "anna")] {
            let names = try FileManager.default.contentsOfDirectory(atPath: FolderSync.folder(of: who, in: url).path)
            #expect(!names.contains { $0.contains(other) })
        }
        // Each knows the other is there, so the window says it is shared.
        #expect(anna.folder?.people.map(\.replica) == ["ben"])
        anna.close()
        ben.close()

        // Opened again, the design is everyone's changes.
        let later = try #require(Collaboration.open(url, replica: "anna"))
        #expect(layer(later, "R")?.fill.color == .black && layer(later, "R")?.frame.minX == 300)
        later.close()
    }

    @Test func manyChangesFoldIntoWholesAndANewcomerHasThemAll() throws {
        let folder = syncedFolder()
        defer { done(folder) }
        let url = folder.appendingPathComponent("Long.bezzle")
        try DesignFile.write(design([CanvasTests.rect("R", CGRect(x: 0, y: 0, width: 50, height: 50))]), to: url)
        let anna = try #require(Collaboration.open(url, replica: "anna"))
        for i in 1...60 { edit(anna, "R") { $0.frame.origin.x = CGFloat(i) } }
        let files = try FileManager.default.contentsOfDirectory(atPath: FolderSync.folder(of: "anna", in: url).path)
        let parts = FolderShare.parts(files: files)
        #expect(parts.count < 40)
        #expect(parts.filter { $0.kind == .whole }.count == 2)
        let carl = try #require(Collaboration.open(url, replica: "carl"))
        #expect(layer(carl, "R")?.frame.minX == 60)
        anna.close()
        carl.close()
    }

    @Test func aCopyMadeInTheFinderHasALiveRoomOfItsOwn() throws {
        let folder = syncedFolder()
        defer { done(folder) }
        let url = folder.appendingPathComponent("Original.bezzle"), copy = folder.appendingPathComponent("Copy.bezzle")
        try DesignFile.write(design([CanvasTests.rect("R", .zero)]), to: url)
        let original = try #require(Collaboration.open(url, replica: "anna"))
        original.close()
        try FileManager.default.copyItem(at: url, to: copy)
        let copied = try #require(Collaboration.open(copy, replica: "anna"))
        #expect(copied.liveKeys.room != original.liveKeys.room)
        copied.close()
        // The original is still itself.
        let again = try #require(Collaboration.open(url, replica: "anna"))
        #expect(again.liveKeys.room == original.liveKeys.room)
        again.close()
    }

    @Test func aVersionNamedOnOneMacShowsOnTheOther() throws {
        let folder = syncedFolder()
        defer { done(folder) }
        let url = folder.appendingPathComponent("Versions.bezzle")
        try DesignFile.write(design([CanvasTests.rect("R", .zero)]), to: url)
        let anna = try #require(Collaboration.open(url, replica: "anna"))
        let ben = try #require(Collaboration.open(url, replica: "ben"))
        defer { anna.close(); ben.close() }
        var named = DesignVersion(date: Date(timeIntervalSince1970: 1_000), name: "For the client", by: "Anna", replica: "anna", layers: 1)
        named.shared = true
        let own = DesignVersion(date: Date(timeIntervalSince1970: 2_000), name: nil, by: "Anna", replica: "anna", layers: 1)
        let data = try #require(VersionFiles.pack(BezzleDocument()))
        for v in [named, own] { try VersionFiles.write(data, as: v.id, to: url) }
        try VersionFiles.writeIndex([named, own], to: url, replica: "anna")
        // Each keeps a list of its own, and sees what everyone named.
        #expect(VersionFiles.index(of: url, replica: "anna").map(\.id) == [named.id, own.id])
        #expect(VersionFiles.index(of: url, replica: "ben").map(\.id) == [named.id])
        #expect(!FileManager.default.fileExists(atPath: VersionFiles.folder(of: url).appendingPathComponent("index.json").path))
    }
}
