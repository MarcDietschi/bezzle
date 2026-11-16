import Testing
import AppKit
@testable import Bezzle

/// A design in a folder Google Drive keeps in step, open on several computers. Unlike iCloud
/// Drive, Google Drive keeps each file in a design's package as an item of its own, and keeps
/// every file written under a name as one more item, so that two computers writing one name make
/// two: Google Drive calls the second "photo (1).jpg", and a Mac shows another as "photo 2.jpg".
/// In a design three Macs had open, one picture from the relay was kept five times (2026-11-16).
/// So a Mac writes in a design only names that are its own, takes back in what Google Drive kept
/// twice all the same, and opens a design shared by link that is in its designs folder already
/// rather than making it again as "Poster 2".
@MainActor
@Suite(.serialized)
struct GoogleDriveFolderTests {
    private func syncedFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleDrive-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        SyncedFolders.forTests[folder.path] = "Google Drive"
        return folder
    }

    private func done(_ folder: URL, _ stores: DocumentStore...) {
        for store in stores { store.sharing?.close() }
        DocumentStore.finishSaving()
        SyncedFolders.forTests[folder.path] = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func poster() -> BezzleDocument {
        var doc = BezzleDocument()
        doc.nodes = [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50))]
        return doc
    }

    /// `claiming`: the design is this Mac's copy of its link's room. One process stands for every
    /// Mac here, so a second copy of one link opens without, as on a Mac of its own.
    private func open(_ url: URL, as replica: String, claiming: Bool = true) throws -> DocumentStore {
        let session = try #require(Collaboration.open(url, replica: replica, claiming: claiming))
        let store = DocumentStore(url: url, document: session.document())
        store.sharing = session
        session.attach(to: store)
        return store
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func names(in folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    /// Every file in the design, by path inside it.
    private func files(_ design: URL) -> Set<String> {
        var all = Set<String>()
        let walk = FileManager.default.enumerator(at: design, includingPropertiesForKeys: [.isRegularFileKey])
        while let file = walk?.nextObject() as? URL {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            all.insert(String(file.standardizedFileURL.path.dropFirst(design.standardizedFileURL.path.count + 1)))
        }
        return all
    }

    /// A small picture, as a PNG.
    private func png() throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    // MARK: Names a service gives a second file

    @Test func theNamesServicesGiveASecondFileAreKnown() {
        #expect(FolderShare.numberedCopy("photo 2.jpg") == "photo.jpg")
        #expect(FolderShare.numberedCopy("photo (1).jpg") == "photo.jpg")
        #expect(FolderShare.numberedCopy("Poster 12.bezzle") == "Poster.bezzle")
        #expect(FolderShare.numberedCopy("images 2") == "images")
        #expect(FolderShare.numberedCopy("document (3).json") == "document.json")
        #expect(FolderShare.numberedCopy("Weblaw Print + Media 2.bezzle") == "Weblaw Print + Media.bezzle")
        // Not a second one: no number, a name of its own, or nothing before the number.
        #expect(FolderShare.numberedCopy("photo.jpg") == nil)
        #expect(FolderShare.numberedCopy("Poster copy.bezzle") == nil)
        #expect(FolderShare.numberedCopy("Report 2026.pdf") == nil)
        #expect(FolderShare.numberedCopy("c-001794827369281.lzfse") == nil)
        #expect(FolderShare.numberedCopy(" 2.jpg") == nil)
        #expect(FolderShare.numberedCopy("me.json") == nil)
    }

    // MARK: Copies inside a design

    @Test func whatTheServiceKeptTwiceInsideADesignIsTakenBackIn() throws {
        let folder = syncedFolder()
        let url = folder.appendingPathComponent("Poster.bezzle")
        try DesignFile.write(poster(), to: url)
        let anna = try open(url, as: "anna")
        defer { done(folder, anna) }
        DocumentStore.finishSaving()
        let images = url.appendingPathComponent("images", isDirectory: true)
        let versions = url.appendingPathComponent("versions", isDirectory: true)
        // The same picture from the relay, written on three computers.
        for name in ["photo.jpg", "photo (1).jpg", "photo 2.jpg"] { try write("the photo", to: images.appendingPathComponent(name)) }
        // A picture the design shows by a name like a copy's, the same as another.
        try write("a logo", to: images.appendingPathComponent("logo.png"))
        try write("a logo", to: images.appendingPathComponent("logo 2.png"))
        // One that differs under one name is left: nothing says which is meant.
        try write("first", to: images.appendingPathComponent("odd.png"))
        try write("second", to: images.appendingPathComponent("odd 2.png"))
        // A version named elsewhere, written on two computers.
        let version = UUID().uuidString
        try write("the version", to: versions.appendingPathComponent("\(version).lzfse"))
        try write("the version", to: versions.appendingPathComponent("\(version) (1).lzfse"))
        // A folder made on two computers at once: what is only in the second goes into the first.
        try write("another photo", to: url.appendingPathComponent("images 2/other.jpg"))
        try write("the photo", to: url.appendingPathComponent("images 2/photo.jpg"))
        // The design's own file written on two at once, and its Finder picture.
        try write("{}", to: url.appendingPathComponent("document 2.json"))
        try write("picture", to: url.appendingPathComponent("QuickLook/Thumbnail.jpg"))
        try write("another picture", to: url.appendingPathComponent("QuickLook/Thumbnail 2.jpg"))
        // A room begun on another computer before this one's came: everyone keeps the first made.
        let room = try #require(FolderShare.room(of: url))
        let earlier = FolderShare.Room.fresh(at: room.made - 1000)
        try FolderShare.encode(earlier)!.write(to: url.appendingPathComponent("sharing/room 2.json"))

        let bin = folder.appendingPathComponent("Bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let taken = FolderShare.foldCopiesInside(url, using: ["logo 2.png"]) { try FileManager.default.moveItem(at: $0, to: bin.appendingPathComponent($0.lastPathComponent)) }
        #expect(!taken.isEmpty)

        #expect(names(in: images) == ["photo.jpg", "logo.png", "logo 2.png", "odd.png", "odd 2.png", "other.jpg"])
        #expect((try? String(contentsOf: images.appendingPathComponent("other.jpg"), encoding: .utf8)) == "another photo")
        #expect(names(in: versions) == ["\(version).lzfse"])
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("images 2").path))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("document 2.json").path))
        #expect(names(in: bin) == ["document 2.json"])
        #expect(names(in: url.appendingPathComponent("QuickLook")) == ["Thumbnail.jpg"])
        #expect(FolderShare.room(of: url) == earlier)
        #expect(!names(in: url.appendingPathComponent("sharing")).contains("room 2.json"))
        // The design opens as before.
        #expect(FolderShare.document(of: url) != nil)
        // Nothing more to take in, and nothing is held for it.
        #expect(FolderShare.foldCopiesInside(url, using: ["logo 2.png"]) { _ in Issue.record("Put away again") }.isEmpty)
    }

    @Test func aRoomBegunLaterElsewhereIsPutAway() throws {
        let folder = syncedFolder()
        let url = folder.appendingPathComponent("Poster.bezzle")
        try DesignFile.write(poster(), to: url)
        let anna = try open(url, as: "anna")
        defer { done(folder, anna) }
        let room = try #require(FolderShare.room(of: url))
        try FolderShare.encode(FolderShare.Room.fresh(at: room.made + 1000))!.write(to: url.appendingPathComponent("sharing/room (1).json"))
        var discarded: [String] = []
        FolderShare.foldCopiesInside(url) { discarded.append($0.lastPathComponent); try FileManager.default.removeItem(at: $0) }
        #expect(discarded == ["room (1).json"])
        #expect(FolderShare.room(of: url) == room)
    }

    // MARK: A Mac writes only its own names

    @Test func aVersionNamedElsewhereWaitsBesideTheDesign() throws {
        let folder = syncedFolder()
        let url = folder.appendingPathComponent("Poster.bezzle")
        try DesignFile.write(poster(), to: url)
        let ben = try open(url, as: "ben")
        defer { done(folder, ben); try? FileManager.default.removeItem(at: Arrivals.folder(of: url)) }
        DocumentStore.finishSaving()
        let before = files(url)
        var doc = poster()
        doc.nodes[0].name = "Named"
        let version = DesignVersion(date: Date(), name: "Anna's", by: "Anna", replica: "anna", layers: 1, shared: true)
        ben.versions.arrived(version, data: try #require(VersionFiles.pack(doc)))
        DocumentStore.finishSaving()
        // Ben's Mac only looked on: nothing is written in the design, and the version shows.
        #expect(files(url) == before)
        #expect(ben.versions.list.contains { $0.id == version.id })
        #expect(ben.versions.document(version.id)?.nodes.first?.name == "Named")
        #expect(FileManager.default.fileExists(atPath: Arrivals.version(version.id, of: url).path))

        // The folder has not brought it by Ben's next change of his own: it goes in then.
        Arrivals.grace = 0
        defer { Arrivals.grace = 120 }
        ben.edit("Move") { $0.nodes[0].frame.origin.x = 40 }
        ben.save()
        DocumentStore.finishSaving()
        DocumentStore.finishSaving()
        #expect(FileManager.default.fileExists(atPath: VersionFiles.file(version.id, of: url).path))
        #expect(!FileManager.default.fileExists(atPath: Arrivals.version(version.id, of: url).path))
    }

    @Test func aPictureFromTheRelayIsWrittenInOnlyIfTheFolderDoesNotBringIt() throws {
        let folder = syncedFolder()
        let url = folder.appendingPathComponent("Poster.bezzle")
        try DesignFile.write(poster(), to: url)
        defer { done(folder); try? FileManager.default.removeItem(at: Arrivals.folder(of: url)) }
        let images = url.appendingPathComponent("images", isDirectory: true)
        let picture = try png()
        let before = files(url)
        try CloudShare.keep(picture: picture, named: "photo.png", in: url)
        // Beside the design, not in it, and shown from there.
        #expect(files(url) == before)
        #expect(Arrivals.hasPicture("photo.png", of: url))
        #expect(Assets(design: url).image("photo.png") != nil)

        // The folder brings the one its Mac wrote: the one beside it is forgotten, not written.
        try picture.write(to: images.appendingPathComponent("photo.png"))
        Arrivals.grace = 0
        defer { Arrivals.grace = 120 }
        Arrivals.settle(url)
        #expect(names(in: images) == ["photo.png"])
        #expect(!FileManager.default.fileExists(atPath: Arrivals.folder(of: url).path))

        // One the folder never brings, from someone with the link alone: in, with a change made here.
        try CloudShare.keep(picture: picture, named: "theirs.png", in: url)
        Arrivals.grace = 60
        Arrivals.settle(url)
        #expect(names(in: images) == ["photo.png"])
        Arrivals.settle(url, now: Date().addingTimeInterval(61))
        #expect(names(in: images) == ["photo.png", "theirs.png"])
        #expect(!FileManager.default.fileExists(atPath: Arrivals.folder(of: url).path))
    }

    @Test func outsideASyncedFolderAPictureFromTheRelayGoesStraightIn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleLocal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Poster.bezzle")
        try DesignFile.write(poster(), to: url)
        try CloudShare.keep(picture: Data("p".utf8), named: "photo.png", in: url)
        #expect(names(in: url.appendingPathComponent("images")) == ["photo.png"])
        #expect(!FileManager.default.fileExists(atPath: Arrivals.folder(of: url).path))
    }

    // MARK: Made again by a link

    @Test func aLinksDesignAlreadyInTheFolderIsFoundByItsLink() throws {
        let folder = syncedFolder()
        defer { done(folder) }
        let secret = ShareKeys.newSecret().base64URL
        let poster = folder.appendingPathComponent("Poster.bezzle"), other = folder.appendingPathComponent("Other.bezzle")
        try DesignFile.write(self.poster(), to: poster)
        try DesignFile.write(self.poster(), to: other)
        try SharingFiles.write(ShareLink(secret: ShareKeys.newSecret().base64URL, title: "Other"), to: other)
        #expect(Sharing.design(sharedAs: secret, among: [poster, other]) == nil)
        try SharingFiles.write(ShareLink(secret: secret, title: "Poster", ownerName: "Anna"), to: poster)
        #expect(Sharing.design(sharedAs: secret, among: [other, poster]) == poster.standardizedFileURL)
    }

    @Test func aDesignMadeAgainByItsLinkBesideItIsTakenIn() throws {
        let folder = syncedFolder()
        let url = folder.appendingPathComponent("Poster.bezzle")
        try DesignFile.write(poster(), to: url)
        let secret = ShareKeys.newSecret().base64URL
        try SharingFiles.write(ShareLink(secret: secret, title: "Poster", ownerName: "Anna"), to: url)
        let anna = try open(url, as: "anna")
        DocumentStore.finishSaving()
        // Ben's Mac opened the link with the design in its designs folder already: Poster 2, the
        // same design from the relay, with a folder room of its own and Ben's change in it.
        let copy = folder.appendingPathComponent("Poster 2.bezzle")
        try FileManager.default.copyItem(at: url, to: copy)
        try FileManager.default.removeItem(at: FolderShare.roomURL(of: copy))
        try FileManager.default.removeItem(at: FolderShare.people(of: copy))
        let ben = try open(copy, as: "ben", claiming: false)
        ben.edit("Colour") { $0.nodes[0].fill.color = .black }
        ben.save()
        DocumentStore.finishSaving()
        defer { done(folder, anna, ben) }
        #expect(FolderShare.room(of: copy)?.seed != FolderShare.room(of: url)?.seed)
        #expect(FolderSync.copiesFromTheService(of: url).map(\.lastPathComponent) == ["Poster 2.bezzle"])
        let bin = folder.appendingPathComponent("Bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        #expect(FolderSync.foldCopies(beside: url, open: []) { try FileManager.default.moveItem(at: $0, to: bin.appendingPathComponent($0.lastPathComponent)) })
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(FolderShare.document(of: url)?.nodes.first?.fill.color == .black)
    }
}
