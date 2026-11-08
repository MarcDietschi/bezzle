import Testing
import AppKit
import CryptoKit
@testable import Bezzle

/// A design shared through a synced folder, worked on by two Macs and by Bezzle for Windows at
/// once (Windows/Sources/BezzleShare, run in the Windows VM): the Macs here, as FolderShareTests
/// has them, and in between the stages the folder kept in step by hand, as the sync service would.
/// Off unless `TEST_RUNNER_BEZZLE_WINDOWS_FOLDER` names a folder; each run does the next stage, as
/// `stage.txt` there says:
///
/// 0. Anna and Ben share Poster.bezzle and change it, Anna enough to fold, and Anna names a version.
/// 1. Windows has opened it and changed it (not here yet): Anna changes it meanwhile, adding a picture.
/// 2. Windows took Anna's change in and changed it again, and its files came here: everything
///    anyone did is in the design on every Mac, the same design Windows has, and Windows wrote
///    only in its own folder.
@MainActor
@Suite(.serialized)
struct WindowsShareTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BEZZLE_WINDOWS_FOLDER"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    private func layer(_ session: Collaboration, _ name: String) -> Node? {
        session.state.flatDesign().document().allNodes.first { $0.name == name }
    }

    private func edit(_ session: Collaboration, _ name: String, _ change: (inout Node) -> Void) {
        var doc = session.state.flatDesign().document()
        guard let id = doc.allNodes.first(where: { $0.name == name })?.id else { Issue.record("No layer \(name)"); return }
        doc.update(id, change)
        session.takeIn(doc)
        session.persist()
        DocumentStore.finishSaving()
    }

    /// Every file in a folder of one person's, by name, with what it holds.
    private func hashes(_ dir: URL) -> [String: String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var out: [String: String] = [:]
        for name in names {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { continue }
            out[name] = Data(SHA256.hash(data: data)).hex
        }
        return out
    }

    private func json(_ doc: BezzleDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(doc), as: UTF8.self)
    }

    private func read(_ file: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    private func design(in report: [String: Any]) throws -> BezzleDocument {
        let text = try #require(report["design"] as? String)
        return try JSONDecoder().decode(BezzleDocument.self, from: Data(text.utf8))
    }

    /// A small picture, as a PNG: stripes from blue to orange.
    private func picture() throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<64 {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(x) / 63, green: 0.45, blue: 1 - CGFloat(x) / 63, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: 48))
        }
        let image = try #require(ctx.makeImage())
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    @Test(.enabled(if: folder != nil))
    func aFolderSharedWithWindows() throws {
        let folder = try #require(Self.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        SyncedFolders.forTests[folder.path] = "Google Drive"
        defer { SyncedFolders.forTests[folder.path] = nil }
        let url = folder.appendingPathComponent("Poster.bezzle")
        let stageFile = folder.appendingPathComponent("stage.txt")
        let stage = (try? String(contentsOf: stageFile, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let anna = FolderSync.folder(of: "anna", in: url), ben = FolderSync.folder(of: "ben", in: url)

        switch stage {
        case 0:
            var board = Node(kind: .artboard, name: "Poster", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            board.children = [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50)),
                              CanvasTests.rect("S", CGRect(x: 100, y: 10, width: 50, height: 50)),
                              CanvasTests.rect("T", CGRect(x: 200, y: 10, width: 50, height: 50)),
                              AdaptTests.text("Shared with Windows", 24, at: CGPoint(x: 20, y: 120))]
            var doc = BezzleDocument()
            doc.nodes = [board]
            try DesignFile.write(doc, to: url)
            let a = try #require(Collaboration.open(url, replica: "anna"))
            let b = try #require(Collaboration.open(url, replica: "ben"))
            edit(a, "R") { $0.frame.origin.x = 300 }
            edit(b, "R") { $0.fill.color = .black }
            edit(b, "S") { $0.name = "S, renamed" }
            // Enough of Anna's for her changes to fold into wholes.
            for i in 1...30 { edit(a, "T") { $0.frame.origin.y = CGFloat(i) } }
            a.folder?.lookForTesting(for: a)
            b.folder?.lookForTesting(for: b)
            #expect(a.state == b.state)
            // A version Anna named, for everyone.
            var named = DesignVersion(date: Date(), name: "For the client", by: "Anna", replica: "anna", layers: 5)
            named.shared = true
            try VersionFiles.write(try #require(VersionFiles.pack(a.state.flatDesign().document())), as: named.id, to: url)
            try VersionFiles.writeIndex([named], to: url, replica: "anna")
            let merged = a.state.flatDesign().document()
            a.close()
            b.close()
            DocumentStore.finishSaving()
            #expect(FolderShare.parts(files: Array(hashes(anna).keys)).contains { $0.kind == .whole })
            try JSONSerialization.data(withJSONObject: ["design": try json(merged), "anna": hashes(anna), "ben": hashes(ben)])
                .write(to: folder.appendingPathComponent("mac-0.json"))
            try "1".write(to: stageFile, atomically: true, encoding: .utf8)

        case 1:
            // Windows has the design open and has changed it; its files are not here yet.
            let a = try #require(Collaboration.open(url, replica: "anna"))
            edit(a, "R") { $0.frame.origin.y = 222 }
            edit(a, "T") { $0.name = "T, later on the Mac" }
            let images = url.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try picture().write(to: images.appendingPathComponent("photo.png"))
            var doc = a.state.flatDesign().document()
            var p = CanvasTests.rect("P", CGRect(x: 280, y: 180, width: 96, height: 72))
            p.fill.image = ImageFill(asset: "photo.png", size: CGSize(width: 64, height: 48))
            doc.nodes[0].children.append(p)
            a.takeIn(doc)
            a.persist()
            a.close()
            DocumentStore.finishSaving()
            try JSONSerialization.data(withJSONObject: ["anna": hashes(anna), "ben": hashes(ben)]).write(to: folder.appendingPathComponent("mac-1.json"))
            try "2".write(to: stageFile, atomically: true, encoding: .utf8)

        default:
            // Windows' files have come, and what it wrote down of its own run (windows/).
            let windows = folder.appendingPathComponent("windows", isDirectory: true)
            let opened = try read(windows.appendingPathComponent("opened.json"))
            let looked = try read(windows.appendingPathComponent("look.json"))
            let final = try read(windows.appendingPathComponent("final.json"))
            let replica = try #require(opened["replica"] as? String)
            let mac0 = try read(folder.appendingPathComponent("mac-0.json")), mac1 = try read(folder.appendingPathComponent("mac-1.json"))

            // Windows opened the design as the Macs had it, knew who they were, and saw Anna's version.
            #expect(opened["shared"] as? Bool == true)
            #expect(try design(in: opened).nodes == (try design(in: mac0)).nodes)
            #expect(Set(opened["people"] as? [String] ?? []) == ["anna", "ben"])
            #expect((opened["versions"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == "For the client" })
            // It took in what Anna did while it had the design open.
            #expect(looked["changed"] as? Bool == true)
            let seen = try design(in: looked)
            #expect(seen.allNodes.first { $0.name == "R" }?.frame.minY == 222)
            #expect(seen.allNodes.contains { $0.name == "T, later on the Mac" })
            #expect(seen.allNodes.contains { $0.name == "P" })

            // Windows wrote only in its own folder: Anna's and Ben's files are as the Macs left them.
            #expect(FolderShare.isReplica(replica) && replica != "anna" && replica != "ben")
            #expect(hashes(anna) == (mac1["anna"] as? [String: String] ?? [:]))
            #expect(hashes(ben) == (mac0["ben"] as? [String: String] ?? [:]))
            let mine = FolderSync.folder(of: replica, in: url)
            let parts = FolderShare.parts(files: try FileManager.default.contentsOfDirectory(atPath: mine.path))
            #expect(!parts.isEmpty)
            let me = try #require(FolderShare.decode(FolderShare.Person.self, from: Data(contentsOf: mine.appendingPathComponent(FolderShare.personFile))))
            #expect(me.replica == replica && me.app == "windows")
            let people = try FileManager.default.contentsOfDirectory(atPath: FolderSync.peopleFolder(of: url).path).filter { !$0.hasPrefix(".") }
            #expect(Set(people) == ["anna", "ben", replica])

            // On the Macs, nothing anyone did is lost.
            let a = try #require(Collaboration.open(url, replica: "anna"))
            let carl = try #require(Collaboration.open(url, replica: "carl"))
            defer { a.close(); carl.close(); DocumentStore.finishSaving() }
            for session in [a, carl] {
                let r = try #require(layer(session, "R"))
                #expect(r.frame.minX == 300 && r.frame.minY == 222)
                #expect(r.fill.color == .black)
                #expect(r.opacity == 0.5)
                #expect(layer(session, "S, from Windows") != nil)
                let t = try #require(layer(session, "T, later on the Mac"))
                #expect(t.frame.minY == 30)
                let w = try #require(layer(session, "W"))
                #expect(w.frame.minX == 60 && w.fill.color == RGBA(r: 0.2, g: 0.6, b: 0.3, a: 1))
                #expect(layer(session, "P")?.fill.image?.asset == "photo.png")
                // What nobody changed is as it was: Windows set no text of its own.
                #expect(layer(session, "Shared with Windows") == (try design(in: mac0)).allNodes.first { $0.name == "Shared with Windows" })
            }
            #expect(a.state == carl.state)
            // The same design on Windows as on the Macs.
            let windowsDesign = try design(in: final)
            let macDesign = a.state.flatDesign().document()
            #expect(windowsDesign == macDesign)
            print("Windows' design written the same, to the byte: \((final["design"] as? String) == (try json(macDesign)))")
            // The version Windows named is everyone's.
            let fromWindows = VersionFiles.index(of: url, replica: "anna").first { $0.name == "From Windows" }
            #expect(fromWindows?.replica == replica && fromWindows?.shared == true)
            if let fromWindows { #expect(VersionFiles.read(fromWindows.id, of: url) != nil) }
            try "3".write(to: stageFile, atomically: true, encoding: .utf8)
        }
    }

    // MARK: By link, through the relay

    nonisolated private static let linkFolder = ProcessInfo.processInfo.environment["BEZZLE_WINDOWS_LINK"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    nonisolated private static let relay = ProcessInfo.processInfo.environment["BEZZLE_RELAY_TEST"].flatMap(URL.init(string:))

    /// A Mac's session in a design of its own, its room looked at through the relay.
    private func session(_ url: URL, _ replica: String) throws -> Collaboration {
        let session = try #require(Collaboration.open(url, replica: replica, claiming: false))
        session.cloud?.start(for: session)
        return session
    }

    /// A design shared by link, through the relay itself running on this Mac (`cd Relay && npx
    /// wrangler dev --port 8790 --ip 0.0.0.0`), worked on by two Macs and by Bezzle for Windows
    /// at once (bezzle-share's `link`), the stages as above. Off unless `TEST_RUNNER_BEZZLE_RELAY_TEST`
    /// is the relay and `TEST_RUNNER_BEZZLE_WINDOWS_LINK` names a folder:
    ///
    /// 0. Anna shares Poster.bezzle, with a picture; Ben opens the link; both change it. The link,
    ///    and keys and something sealed to check Windows against, go to link.json.
    /// 1. Windows opened the link and changed it, and named a version: Anna takes that in and
    ///    changes it again, as Ben does.
    /// 2. Windows took that in and changed it again: everything anyone did is on every copy, the
    ///    same design as Windows'; Windows wrote only records of its own. Anna stops sharing.
    /// 3. Windows keeps it as it last was, read only.
    @Test(.enabled(if: linkFolder != nil && relay != nil))
    func aLinkSharedWithWindows() async throws {
        let folder = try #require(Self.linkFolder), address = try #require(Self.relay)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let server = RelayServer(base: address)
        Sharing.shared.server = server
        defer { Sharing.shared.server = nil }
        let stageFile = folder.appendingPathComponent("stage.txt")
        let stage = (try? String(contentsOf: stageFile, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let annaURL = folder.appendingPathComponent("anna/Poster.bezzle"), benURL = folder.appendingPathComponent("ben/Poster.bezzle")
        let linkFile = folder.appendingPathComponent("link.json")

        switch stage {
        case 0:
            let secret = ShareKeys.newSecret()
            let keys = try #require(ShareKeys(secret: secret))
            let owner = ShareKeys.newSecret().base64URL
            try await server.create(keys.room, hashes: ["read": Sharing.hash(keys.readToken), "write": Sharing.hash(keys.writeToken), "owner": Sharing.hash(owner)])
            Sharing.shared.own(keys.room, with: owner)
            var board = Node(kind: .artboard, name: "Poster", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            var p = CanvasTests.rect("P", CGRect(x: 280, y: 180, width: 96, height: 72))
            p.fill.image = ImageFill(asset: "photo.png", size: CGSize(width: 64, height: 48))
            board.children = [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50)),
                              CanvasTests.rect("S", CGRect(x: 100, y: 10, width: 50, height: 50)),
                              CanvasTests.rect("T", CGRect(x: 200, y: 10, width: 50, height: 50)),
                              AdaptTests.text("Shared with Windows", 24, at: CGPoint(x: 20, y: 120)), p]
            var doc = BezzleDocument()
            doc.nodes = [board]
            try FileManager.default.createDirectory(at: annaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DesignFile.write(doc, to: annaURL)
            let images = annaURL.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
            try picture().write(to: images.appendingPathComponent("photo.png"))
            let link = ShareLink(secret: secret.base64URL, title: "Poster", ownerName: "Anna")
            try SharingFiles.write(link, to: annaURL)
            let anna = try session(annaURL, "anna")
            try await anna.cloud?.sendMeta(ShareMeta(title: "Poster", owner: "Anna", made: Collaboration.now))
            anna.cloud?.offer(["photo.png"])
            await anna.cloud?.syncForTesting()

            // Ben opens the link, as Sharing.accept makes the design.
            Sharing.shared.disownForTesting(keys.room)
            let arrived = try await CloudShare.download(keys, from: server) { _ in }
            Sharing.shared.own(keys.room, with: owner)
            try FileManager.default.createDirectory(at: benURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DesignFile.write(arrived.state.flatDesign().document(), to: benURL)
            try SharingFiles.write(ShareLink(secret: link.secret, title: arrived.meta?.title, ownerName: arrived.meta?.owner), to: benURL)
            _ = FolderSync.open(benURL, replica: "ben", seed: arrived.state)
            CloudShare.keep(arrived.progress, of: benURL, replica: "ben")
            DocumentStore.finishSaving()
            let ben = try session(benURL, "ben")
            edit(anna, "R") { $0.frame.origin.x = 300 }
            edit(ben, "R") { $0.fill.color = .black }
            edit(ben, "S") { $0.name = "S, renamed" }
            Sharing.shared.disownForTesting(keys.room)
            await ben.cloud?.syncForTesting()
            Sharing.shared.own(keys.room, with: owner)
            await anna.cloud?.syncForTesting()
            Sharing.shared.disownForTesting(keys.room)
            await ben.cloud?.syncForTesting()
            Sharing.shared.own(keys.room, with: owner)
            #expect(anna.state == ben.state)
            let probe = try #require(keys.seal(Data("Sealed on a Mac".utf8), about: "probe"))
            let vector = ["secret": secret.base64URL, "room": keys.room, "read": keys.readToken, "write": keys.writeToken,
                          "picture": keys.pictureName("photo.png"), "hash": Sharing.hash(keys.writeToken),
                          "sealed": probe.base64EncodedString(), "about": "probe"]
            try JSONSerialization.data(withJSONObject: ["link": try #require(link.page).absoluteString, "vector": vector, "owner": owner,
                                                        "design": try json(anna.state.flatDesign().document()), "picture": Data(SHA256.hash(data: try picture())).hex])
                .write(to: linkFile)
            anna.close()
            ben.close()
            DocumentStore.finishSaving()
            try "1".write(to: stageFile, atomically: true, encoding: .utf8)

        case 1:
            let given = try read(linkFile)
            let vector = try #require(given["vector"] as? [String: String])
            let secret = try #require(vector["secret"])
            let keys = try #require(ShareKeys(link: secret))
            let owner = try #require(given["owner"] as? String)
            let windows = try read(folder.appendingPathComponent("windows/keys.json"))
            // Windows makes the same keys from the link, opens what a Mac sealed, and seals what a Mac opens.
            for name in ["room", "read", "write", "picture", "hash", "secretFromLink", "isLink"] { #expect(windows[name] as? Bool == true, "\(name)") }
            #expect(windows["opened"] as? String == "Sealed on a Mac")
            let theirs = try #require((windows["sealed"] as? String).flatMap { Data(base64Encoded: $0) })
            #expect(keys.open(theirs, about: "probe") == Data("Sealed on Windows".utf8))
            #expect(keys.open(theirs, about: "something else") == nil)
            Sharing.shared.own(keys.room, with: owner)
            let anna = try session(annaURL, "anna")
            await anna.cloud?.syncForTesting()
            // Windows' first changes came through the relay.
            #expect(layer(anna, "R")?.opacity == 0.5)
            #expect(layer(anna, "S, from Windows") != nil)
            #expect(layer(anna, "W") != nil)
            edit(anna, "R") { $0.frame.origin.y = 222 }
            edit(anna, "T") { $0.name = "T, later on the Mac" }
            await anna.cloud?.syncForTesting()
            Sharing.shared.disownForTesting(keys.room)
            let ben = try session(benURL, "ben")
            await ben.cloud?.syncForTesting()
            #expect(ben.state == anna.state)
            Sharing.shared.own(keys.room, with: owner)
            anna.close()
            ben.close()
            DocumentStore.finishSaving()
            try "2".write(to: stageFile, atomically: true, encoding: .utf8)

        case 2:
            let given = try read(linkFile)
            let vector = try #require(given["vector"] as? [String: String])
            let secret = try #require(vector["secret"])
            let keys = try #require(ShareKeys(link: secret))
            let owner = try #require(given["owner"] as? String)
            let windows = folder.appendingPathComponent("windows", isDirectory: true)
            let opened = try read(windows.appendingPathComponent("opened.json"))
            let looked = try read(windows.appendingPathComponent("look.json"))
            let final = try read(windows.appendingPathComponent("final.json"))
            let replica = try #require(opened["replica"] as? String)
            // Windows opened it as the Macs had it, marked as Anna's, with the picture.
            #expect(try design(in: opened) == (try design(in: given)))
            #expect(opened["mark"] as? String == "sharedBy(Optional(\"Anna\"))")
            #expect((opened["pictures"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == "photo.png" && $0["sha256"] as? String == given["picture"] as? String })
            #expect(looked["changed"] as? Bool == true)
            #expect(try design(in: looked).allNodes.first { $0.name == "R" }?.frame.minY == 222)

            Sharing.shared.own(keys.room, with: owner)
            let anna = try session(annaURL, "anna")
            await anna.cloud?.syncForTesting()
            Sharing.shared.disownForTesting(keys.room)
            let ben = try session(benURL, "ben")
            await ben.cloud?.syncForTesting()
            let arrived = try await CloudShare.download(keys, from: server) { _ in }
            Sharing.shared.own(keys.room, with: owner)
            for state in [anna.state, ben.state, arrived.state] {
                let doc = state.flatDesign().document()
                func named(_ name: String) -> Node? { doc.allNodes.first { $0.name == name } }
                let r = try #require(named("R"))
                #expect(r.frame.minX == 300 && r.frame.minY == 222 && r.fill.color == .black && r.opacity == 0.5)
                #expect(named("S, from Windows") != nil && named("T, later on the Mac") != nil)
                #expect(named("W")?.frame.minX == 60)
                #expect(named("P")?.fill.image?.asset == "photo.png")
                #expect(named("Shared with Windows") == (try design(in: given)).allNodes.first { $0.name == "Shared with Windows" })
            }
            #expect(anna.state == ben.state && ben.state == arrived.state)
            // The same design on Windows.
            let macDesign = anna.state.flatDesign().document()
            #expect(try design(in: final) == macDesign)
            print("Windows' design written the same, to the byte: \((final["design"] as? String) == (try json(macDesign)))")
            // In the room, Windows wrote records of its own alone, said who it is, and named a version.
            let fetched = try await CloudShare.fetch(keys, from: server, progress: CloudShare.Progress(), fully: true, replica: "zed")
            #expect(fetched.people[replica]?.app == "windows")
            let fromWindows = try #require(fetched.versions.first { $0.name == "From Windows" })
            #expect(fromWindows.replica == replica)
            let key = ShareRecord.versionDesign(fromWindows.id).key
            let packed = try #require(try await server.get(keys.room, key, read: keys.readToken).flatMap { keys.open($0, about: key) })
            #expect(VersionFiles.unpack(packed) != nil)
            let listing = try await server.list(keys.room, since: 0, read: keys.readToken)
            let parts = listing.records.compactMap { FolderShare.Part.record($0.key) }
            #expect(Set(parts.map(\.replica)) == ["anna", "ben", replica])
            #expect(parts.contains { $0.replica == replica && $0.part.kind == .changes })
            // Anna stops sharing it; the others keep it as it last was.
            try await server.unshare(keys.room, write: keys.writeToken, owner: owner)
            Sharing.shared.disownForTesting(keys.room)
            await ben.cloud?.syncForTesting()
            #expect(ben.isReadOnly)
            anna.close()
            ben.close()
            DocumentStore.finishSaving()
            try "3".write(to: stageFile, atomically: true, encoding: .utf8)

        default:
            let ended = try read(folder.appendingPathComponent("windows/ended.json"))
            #expect(ended["readOnly"] as? Bool == true)
            #expect(ended["mark"] as? String == "ended")
            #expect(ended["linkEnded"] as? Bool == true)
            #expect(ended["unchanged"] as? Bool == true)
            try "4".write(to: stageFile, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Live, through the relay

    nonisolated private static let liveFolder = ProcessInfo.processInfo.environment["BEZZLE_WINDOWS_LIVE"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    /// What a Mac hears in the live room.
    private final class Heard {
        var others: [UInt32: LiveHello] = [:]
        var presence: [UInt32: LivePresence] = [:]
        var changes: [SharedDesign] = []
        var records = 0
        var glimpses: [LiveGlimpse] = []
        var wants: [String] = []
    }

    /// The live room of a design shared by link, through the relay itself (as aLinkSharedWithWindows):
    /// Anna's Mac, here with its own LiveSocket and LiveKey, and Windows (bezzle-share's `live`) in
    /// it at once. Off unless `TEST_RUNNER_BEZZLE_RELAY_TEST` and `TEST_RUNNER_BEZZLE_WINDOWS_LIVE`:
    ///
    /// 0. Anna shares Poster.bezzle; the link goes to link.json.
    /// 1. Windows is in the room: each hears who the other is and where they point; Anna winks and
    ///    renames R, sent live and to the room's records; Windows answers live with a change of its
    ///    own, merged here.
    /// 2. What Windows heard: Anna, her pointer, her wink, her change, the records moving on, and
    ///    the pencil every computer gives her.
    @Test(.enabled(if: liveFolder != nil && relay != nil))
    func aLiveRoomWithWindows() async throws {
        let folder = try #require(Self.liveFolder), address = try #require(Self.relay)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let server = RelayServer(base: address)
        Sharing.shared.server = server
        defer { Sharing.shared.server = nil }
        let stageFile = folder.appendingPathComponent("stage.txt")
        let stage = (try? String(contentsOf: stageFile, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let annaURL = folder.appendingPathComponent("anna/Poster.bezzle"), linkFile = folder.appendingPathComponent("link.json")

        switch stage {
        case 0:
            let secret = ShareKeys.newSecret()
            let keys = try #require(ShareKeys(secret: secret))
            let owner = ShareKeys.newSecret().base64URL
            try await server.create(keys.room, hashes: ["read": Sharing.hash(keys.readToken), "write": Sharing.hash(keys.writeToken), "owner": Sharing.hash(owner)])
            Sharing.shared.own(keys.room, with: owner)
            var board = Node(kind: .artboard, name: "Poster", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            board.children = [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50)), CanvasTests.rect("S", CGRect(x: 100, y: 10, width: 50, height: 50))]
            var doc = BezzleDocument()
            doc.nodes = [board]
            try FileManager.default.createDirectory(at: annaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DesignFile.write(doc, to: annaURL)
            let link = ShareLink(secret: secret.base64URL, title: "Poster", ownerName: "Anna")
            try SharingFiles.write(link, to: annaURL)
            let anna = try session(annaURL, "anna")
            try await anna.cloud?.sendMeta(ShareMeta(title: "Poster", owner: "Anna", made: Collaboration.now))
            await anna.cloud?.syncForTesting()
            anna.close()
            DocumentStore.finishSaving()
            try JSONSerialization.data(withJSONObject: ["link": try #require(link.page).absoluteString, "secret": secret.base64URL, "owner": owner]).write(to: linkFile)
            try "1".write(to: stageFile, atomically: true, encoding: .utf8)

        case 1:
            let given = try read(linkFile)
            let secret = try #require(given["secret"] as? String)
            let keys = try #require(ShareKeys(link: secret))
            Sharing.shared.own(keys.room, with: try #require(given["owner"] as? String))
            let anna = try session(annaURL, "anna")
            defer { anna.close(); DocumentStore.finishSaving() }
            let key = LiveKey(keys), heard = Heard()
            let hello = LiveHello(replica: "anna", name: "Anna", timeZone: "Europe/Zurich")
            let here = LivePresence(pointer: CGPoint(x: 200, y: 150), view: CGRect(x: 0, y: 0, width: 400, height: 300), selection: [], tool: "select")
            var parts = URLComponents(url: address, resolvingAgainstBaseURL: false)!
            parts.scheme = parts.scheme == "https" ? "wss" : "ws"
            let socket = LiveSocket(room: keys.room, read: keys.readToken, relay: try #require(parts.url))
            defer { socket.stop() }
            func send(_ message: LiveMessage, to peer: UInt32? = nil) {
                guard let sealed = key.seal(message) else { return }
                socket.send(peer.map { LiveFrame.to($0, sealed) } ?? LiveFrame.toAll(sealed), droppable: false)
            }
            socket.onFrame = { frame in
                switch frame {
                case .welcome(_, let others) where !others.isEmpty:
                    send(.hello(hello))
                    send(.presence(here))
                case .joined(let peer):
                    send(.hello(hello), to: peer)
                    send(.presence(here), to: peer)
                case .records:
                    heard.records += 1
                case .message(let from, let sealed):
                    switch key.open(sealed) {
                    case .hello(let h)?:
                        heard.others[from] = h
                        if h.ask == true { send(.hello(hello), to: from) }
                    case .presence(let p)?: heard.presence[from] = p
                    case .changes(let c)?: heard.changes.append(c)
                    default: break
                    }
                default: break
                }
            }
            socket.start()
            func until(_ seconds: Double, _ done: () -> Bool) async throws {
                let start = Date()
                while !done(), Date().timeIntervalSince(start) < seconds { try await Task.sleep(for: .milliseconds(100)) }
            }
            // Who Windows is, and where it points.
            try await until(60) { heard.others.values.contains { $0.replica != "anna" } && heard.presence.values.contains { $0.pointer == CGPoint(x: 123, y: 45) } }
            let windows = try #require(heard.others.first { $0.value.replica != "anna" })
            #expect(FolderShare.isReplica(windows.value.replica))
            #expect(!windows.value.name.isEmpty && windows.value.timeZone != nil)
            #expect(heard.presence[windows.key]?.tool == "select")
            // A wink, and a change made a moment ago, live; then the same change in the room's records.
            send(.wink(CGPoint(x: 77, y: 88)))
            var doc = anna.state.flatDesign().document()
            let r = try #require(doc.allNodes.first { $0.name == "R" }?.id)
            doc.update(r) { $0.name = "R, renamed live" }
            let before = anna.state.clock.time
            anna.takeIn(doc)
            send(.changes(anna.state.changes(by: "anna", after: before)))
            await anna.cloud?.syncForTesting()
            // Windows answers live.
            try await until(60) {
                var merged = anna.state
                for c in heard.changes { merged.merge(c) }
                return merged.flatDesign().document().allNodes.contains { $0.name == "S, from Windows live" }
            }
            anna.receive(heard.changes, from: .relay)
            #expect(layer(anna, "S, from Windows live") != nil)
            #expect(layer(anna, "R, renamed live") != nil)
            try JSONSerialization.data(withJSONObject: ["windows": windows.value.replica, "design": try json(anna.state.flatDesign().document())])
                .write(to: folder.appendingPathComponent("mac-live.json"))
            try "2".write(to: stageFile, atomically: true, encoding: .utf8)

        default:
            let mac = try read(folder.appendingPathComponent("mac-live.json"))
            let live = try read(folder.appendingPathComponent("windows/live.json"))
            let windows = try #require(mac["windows"] as? String)
            #expect(Set(live["events"] as? [String] ?? []).isSuperset(of: ["hello", "presence", "wink", "changes", "answered", "records"]))
            let anna = try #require(live["anna"] as? [String: Any])
            #expect(anna["replica"] as? String == "anna" && anna["name"] as? String == "Anna")
            #expect(anna["pointer"] as? [Double] == [200, 150])
            #expect(anna["tool"] as? String == "select")
            #expect(anna["link"] as? String == "live")
            // The pencil every computer in the room gives Anna.
            let pencil = try #require(Pencil.hand(to: ["anna", windows])["anna"])
            let hex = String(format: "%06x", UInt32(pencil.rgb.r * 255) << 16 | UInt32(pencil.rgb.g * 255) << 8 | UInt32(pencil.rgb.b * 255))
            #expect(anna["pencil"] as? String == hex)
            // Once she left, she is gone from the room here too.
            #expect((live["peopleAtTheEnd"] as? [String])?.contains("anna") == false)
            // Windows has the design as Anna has it.
            #expect(try design(in: live).allNodes.map(\.name) == (try design(in: mac)).allNodes.map(\.name))
            try "3".write(to: stageFile, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Glimpses, through the relay

    nonisolated private static let glimpseFolder = ProcessInfo.processInfo.environment["BEZZLE_WINDOWS_GLIMPSES"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    /// A picture with something to see in it, as a JPEG (Anna's) or a PNG (the one Windows places):
    /// a sky going warm towards a horizon, a sun, and a dark hill.
    private func photo(width: Int, height: Int, jpeg: Bool) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let sky = try #require(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                          colors: [CGColor(srgbRed: 0.16, green: 0.36, blue: 0.78, alpha: 1), CGColor(srgbRed: 0.98, green: 0.62, blue: 0.32, alpha: 1)] as CFArray,
                                          locations: [0, 1]))
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: 0, y: CGFloat(height) * 0.3), options: [.drawsAfterEndLocation])
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.93, blue: 0.6, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: CGFloat(width) * 0.62, y: CGFloat(height) * 0.5, width: CGFloat(height) * 0.22, height: CGFloat(height) * 0.22))
        ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.22, blue: 0.16, alpha: 1))
        ctx.move(to: .zero)
        ctx.addCurve(to: CGPoint(x: CGFloat(width), y: CGFloat(height) * 0.18), control1: CGPoint(x: CGFloat(width) * 0.3, y: CGFloat(height) * 0.62),
                     control2: CGPoint(x: CGFloat(width) * 0.6, y: CGFloat(height) * 0.05))
        ctx.addLine(to: CGPoint(x: CGFloat(width), y: 0))
        ctx.fillPath()
        let image = try #require(ctx.makeImage())
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: jpeg ? .jpeg : .png, properties: jpeg ? [.compressionFactor: 0.9] : [:]))
    }

    /// A picture file's pixels, as sRGB RGBA, and its size.
    private func pixels(_ data: Data) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try pixels(image)
    }

    private func pixels(_ image: CGImage) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = try #require(CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (image.width, image.height, bytes)
    }

    /// How far apart two pictures of one size are: the mean and the largest difference of a channel, out of 255.
    private func apart(_ a: (width: Int, height: Int, bytes: [UInt8]), _ b: (width: Int, height: Int, bytes: [UInt8])) -> (mean: Double, most: Int) {
        guard a.width == b.width, a.height == b.height else { return (255, 255) }
        var sum = 0, most = 0
        for k in a.bytes.indices where k % 4 != 3 {
            let d = abs(Int(a.bytes[k]) - Int(b.bytes[k]))
            sum += d
            most = max(most, d)
        }
        return (Double(sum) / Double(a.width * a.height * 3), most)
    }

    /// Glimpses between a Mac and Bezzle for Windows (bezzle-share's `glimpses`) in the live room of
    /// a design shared by link, through the relay itself (as aLinkSharedWithWindows): each shows
    /// the other's picture by its glimpse until the picture comes, as the Mac shows a Mac's. Off
    /// unless `TEST_RUNNER_BEZZLE_RELAY_TEST` and `TEST_RUNNER_BEZZLE_WINDOWS_GLIMPSES`:
    ///
    /// 0. Anna shares Poster.bezzle, with layers Photo and Frame; the link goes to link.json, beside
    ///    anna.jpg (hers) and windows.png (for Windows to place).
    /// 1. Windows is in the room and fills Frame with windows.png: its glimpse comes here at once,
    ///    and opens as the Mac's own do. Anna fills Photo with anna.jpg, which only she has: Windows
    ///    asks for a glimpse of it, shows it so (and says so), then gets the picture from the room.
    ///    What the Mac makes of the same pictures goes to mac/.
    /// 2. What Windows showed (its out folder copied to windows/): Anna's glimpse grown and blurred
    ///    as the Mac grows and blurs it, then her picture itself; its glimpse of windows.png as the
    ///    Mac's glimpse of it.
    @Test(.enabled(if: glimpseFolder != nil && relay != nil))
    func glimpsesWithWindows() async throws {
        let folder = try #require(Self.glimpseFolder), address = try #require(Self.relay)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let server = RelayServer(base: address)
        Sharing.shared.server = server
        defer { Sharing.shared.server = nil }
        let stageFile = folder.appendingPathComponent("stage.txt")
        let stage = (try? String(contentsOf: stageFile, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let annaURL = folder.appendingPathComponent("anna/Poster.bezzle"), linkFile = folder.appendingPathComponent("link.json")
        let mac = folder.appendingPathComponent("mac", isDirectory: true)

        switch stage {
        case 0:
            let secret = ShareKeys.newSecret()
            let keys = try #require(ShareKeys(secret: secret))
            let owner = ShareKeys.newSecret().base64URL
            try await server.create(keys.room, hashes: ["read": Sharing.hash(keys.readToken), "write": Sharing.hash(keys.writeToken), "owner": Sharing.hash(owner)])
            Sharing.shared.own(keys.room, with: owner)
            var board = Node(kind: .artboard, name: "Poster", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            board.children = [CanvasTests.rect("Photo", CGRect(x: 10, y: 10, width: 180, height: 120)),
                              CanvasTests.rect("Frame", CGRect(x: 210, y: 10, width: 180, height: 120)),
                              CanvasTests.rect("S", CGRect(x: 10, y: 200, width: 50, height: 50))]
            var doc = BezzleDocument()
            doc.nodes = [board]
            try FileManager.default.createDirectory(at: annaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DesignFile.write(doc, to: annaURL)
            let link = ShareLink(secret: secret.base64URL, title: "Poster", ownerName: "Anna")
            try SharingFiles.write(link, to: annaURL)
            let anna = try session(annaURL, "anna")
            try await anna.cloud?.sendMeta(ShareMeta(title: "Poster", owner: "Anna", made: Collaboration.now))
            await anna.cloud?.syncForTesting()
            anna.close()
            DocumentStore.finishSaving()
            try photo(width: 1200, height: 800, jpeg: true).write(to: folder.appendingPathComponent("anna.jpg"))
            try photo(width: 900, height: 600, jpeg: false).write(to: folder.appendingPathComponent("windows.png"))
            try JSONSerialization.data(withJSONObject: ["link": try #require(link.page).absoluteString, "secret": secret.base64URL, "owner": owner]).write(to: linkFile)
            try "1".write(to: stageFile, atomically: true, encoding: .utf8)

        case 1:
            let given = try read(linkFile)
            let secret = try #require(given["secret"] as? String)
            let keys = try #require(ShareKeys(link: secret))
            Sharing.shared.own(keys.room, with: try #require(given["owner"] as? String))
            let anna = try session(annaURL, "anna")
            // Her picture reaches the room only once Windows has shown its glimpse.
            anna.cloud?.stop()
            defer { anna.close(); DocumentStore.finishSaving() }
            let images = annaURL.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
            let key = LiveKey(keys), heard = Heard()
            let hello = LiveHello(replica: "anna", name: "Anna", timeZone: "Europe/Zurich")
            let here = LivePresence(pointer: CGPoint(x: 200, y: 150), view: CGRect(x: 0, y: 0, width: 400, height: 300), selection: [], tool: "select")
            var parts = URLComponents(url: address, resolvingAgainstBaseURL: false)!
            parts.scheme = parts.scheme == "https" ? "wss" : "ws"
            let socket = LiveSocket(room: keys.room, read: keys.readToken, relay: try #require(parts.url))
            defer { socket.stop() }
            func send(_ message: LiveMessage, to peer: UInt32? = nil) {
                guard let sealed = key.seal(message) else { return }
                socket.send(peer.map { LiveFrame.to($0, sealed) } ?? LiveFrame.toAll(sealed), droppable: false)
            }
            socket.onFrame = { frame in
                switch frame {
                case .welcome(_, let others) where !others.isEmpty:
                    send(.hello(hello))
                    send(.presence(here))
                case .joined(let peer):
                    send(.hello(hello), to: peer)
                    send(.presence(here), to: peer)
                case .message(let from, let sealed):
                    switch key.open(sealed) {
                    case .hello(let h)?:
                        heard.others[from] = h
                        if h.ask == true { send(.hello(hello), to: from) }
                    case .changes(let c)?: heard.changes.append(c)
                    case .glimpses(let g)?: heard.glimpses += g
                    case .want(let names)?:
                        // As the Mac's LiveRoom answers: glimpses of those it has.
                        heard.wants += names
                        let made = names.compactMap { name in
                            FileManager.default.fileExists(atPath: images.appendingPathComponent(name).path)
                                ? LiveGlimpse.of(images.appendingPathComponent(name), name: name) : nil
                        }
                        if !made.isEmpty { send(.glimpses(made), to: from) }
                    default: break
                    }
                default: break
                }
            }
            socket.start()
            func until(_ seconds: Double, _ done: () -> Bool) async throws {
                let start = Date()
                while !done(), Date().timeIntervalSince(start) < seconds { try await Task.sleep(for: .milliseconds(100)) }
            }
            try await until(60) { heard.others.values.contains { $0.replica != "anna" } }
            #expect(heard.others.values.contains { $0.replica != "anna" })
            // Anna fills Photo with a picture only she has, and says so live.
            let name = UUID().uuidString + ".jpg"
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: folder.appendingPathComponent("anna.jpg"), to: images.appendingPathComponent(name))
            var doc = anna.state.flatDesign().document()
            let photoID = try #require(doc.allNodes.first { $0.name == "Photo" }?.id)
            doc.update(photoID) {
                $0.fill.on = true
                $0.fill.image = ImageFill(asset: name, size: CGSize(width: 1200, height: 800))
            }
            let before = anna.state.clock.time
            anna.takeIn(doc)
            send(.changes(anna.state.changes(by: "anna", after: before)))
            // Windows' glimpse of what it placed, sent at once; and Windows asking for Anna's.
            try await until(60) { !heard.glimpses.isEmpty && heard.wants.contains(name) }
            #expect(heard.wants.contains(name))
            let theirs = try #require(heard.glimpses.first { $0.name != name })
            // It opens as the Mac's own do: a picture a few dozen pixels across, grown and blurred.
            let small = try pixels(theirs.jpeg)
            #expect(max(small.width, small.height) == LiveGlimpse.pixels)
            #expect(theirs.jpeg.count < 4000)
            let grown = try #require(theirs.standIn())
            #expect(max(grown.width, grown.height) == 320)
            // Windows shows Anna's picture by its glimpse, and says so; then it goes to the room.
            try await until(60) {
                var merged = anna.state
                for c in heard.changes { merged.merge(c) }
                return merged.flatDesign().document().allNodes.contains { $0.name == "S, glimpse shown" }
            }
            anna.receive(heard.changes, from: .relay)
            #expect(layer(anna, "S, glimpse shown") != nil)
            anna.cloud?.start(for: anna)
            await anna.cloud?.syncForTesting()
            // What the Mac makes of the same: Windows' glimpse grown, Anna's glimpse and it grown,
            // and the Mac's own glimpse of the picture Windows placed.
            try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
            func png(_ image: CGImage, _ file: String) throws {
                try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: mac.appendingPathComponent(file))
            }
            try theirs.jpeg.write(to: mac.appendingPathComponent("windows-glimpse-received.jpg"))
            try png(grown, "mac-standin-windows.png")
            let annas = try #require(LiveGlimpse.of(images.appendingPathComponent(name), name: name))
            try annas.jpeg.write(to: mac.appendingPathComponent("mac-glimpse-anna.jpg"))
            try png(try #require(annas.standIn()), "mac-standin-anna.png")
            let windowsPicture = try #require(LiveGlimpse.of(folder.appendingPathComponent("windows.png"), name: "windows.png"))
            try windowsPicture.jpeg.write(to: mac.appendingPathComponent("mac-glimpse-windows.jpg"))
            try JSONSerialization.data(withJSONObject: ["anna": name, "windows": theirs.name, "wanted": heard.wants]).write(to: mac.appendingPathComponent("mac-glimpses.json"))
            // A moment for Windows to take the picture from the room.
            try await Task.sleep(for: .seconds(8))
            try "2".write(to: stageFile, atomically: true, encoding: .utf8)

        default:
            let windows = folder.appendingPathComponent("windows", isDirectory: true)
            let said = try read(windows.appendingPathComponent("glimpses.json"))
            let events = said["events"] as? [String] ?? []
            #expect(Set(events).isSuperset(of: ["placed", "stand-in", "arrived"]))
            let macSaid = try read(mac.appendingPathComponent("mac-glimpses.json"))
            #expect(said["theirs"] as? String == macSaid["anna"] as? String)
            #expect(said["placed"] as? String == macSaid["windows"] as? String)
            // Anna's glimpse grown and blurred on Windows as on the Mac, then her picture itself.
            let grownThere = try pixels(Data(contentsOf: windows.appendingPathComponent("windows-standin-anna.png")))
            let grownHere = try pixels(Data(contentsOf: mac.appendingPathComponent("mac-standin-anna.png")))
            let sizes = said["sizes"] as? [String: [Int]] ?? [:]
            #expect(sizes["stand-in"] == [grownHere.width, grownHere.height])
            #expect(sizes["arrived"] == [1200, 800])
            let grownApart = apart(grownThere, grownHere)
            #expect(grownApart.mean < 2, "stand-ins apart by \(grownApart.mean) on average, \(grownApart.most) at most")
            // The glimpse Windows sent is the one it made, and much as the Mac's of the same picture.
            #expect(try Data(contentsOf: windows.appendingPathComponent("windows-glimpse.jpg")) == Data(contentsOf: mac.appendingPathComponent("windows-glimpse-received.jpg")))
            let sentThere = try pixels(Data(contentsOf: windows.appendingPathComponent("windows-glimpse.jpg")))
            let sentHere = try pixels(Data(contentsOf: mac.appendingPathComponent("mac-glimpse-windows.jpg")))
            let sentApart = apart(sentThere, sentHere)
            #expect(sentApart.mean < 6, "glimpses apart by \(sentApart.mean) on average, \(sentApart.most) at most")
            print("glimpses: stand-ins \(grownApart), glimpses \(sentApart)")
            try "3".write(to: stageFile, atomically: true, encoding: .utf8)
        }
    }
}
