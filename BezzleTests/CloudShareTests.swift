import Testing
import AppKit
@testable import Bezzle

/// A relay of the tests' own, keeping rooms as Relay/src/worker.js does (Relay/SHARING.md): the
/// same tokens, writers, write-once records and seqs, in memory.
private final class MemoryRelay: ShareServer, @unchecked Sendable {
    private struct Record {
        var seq: Int64
        var data: Data
    }

    private struct Room {
        var hashes: [String: String]
        var records: [String: Record] = [:]
        var writers: [String: String] = [:]
        var seq: Int64 = 0
        var gone = false
    }

    private var rooms: [String: Room] = [:]
    private let lock = NSLock()
    /// How many times each record was fetched, to tell what was read again.
    private(set) var fetched: [String: Int] = [:]

    private func room(_ id: String, _ token: String, _ kind: String) throws -> Room {
        guard let room = rooms[id] else { throw ShareError.missing }
        if room.gone { throw ShareError.gone }
        guard room.hashes[kind] == Sharing.hash(token) else { throw ShareError.refused(403) }
        return room
    }

    func create(_ id: String, hashes: [String: String]) async throws {
        try lock.withLock {
            guard rooms[id] == nil else { throw ShareError.refused(409) }
            rooms[id] = Room(hashes: hashes)
        }
    }

    func list(_ id: String, since: Int64, read: String) async throws -> ShareListing {
        try lock.withLock {
            let room = try room(id, read, "read")
            let records = room.records.filter { $0.value.seq > since }.sorted { $0.value.seq < $1.value.seq }
                .map { ShareListing.Entry(key: $0.key, seq: $0.value.seq, size: $0.value.data.count) }
            return ShareListing(seq: room.seq, records: records)
        }
    }

    func get(_ id: String, _ key: String, read: String) async throws -> Data? {
        try lock.withLock {
            let room = try room(id, read, "read")
            fetched[key, default: 0] += 1
            return room.records[key]?.data
        }
    }

    func put(_ id: String, _ key: String, _ body: Data, write: String, writer: String?, owner: String?) async throws {
        try lock.withLock {
            var room = try room(id, write, "write")
            guard let record = ShareRecord(key: key) else { throw ShareError.refused(400) }
            switch record {
            case .meta:
                guard let owner, room.hashes["owner"] == Sharing.hash(owner) else { throw ShareError.refused(403) }
            case .person(let replica), .part(let replica, _):
                guard let writer else { throw ShareError.refused(403) }
                if let bound = room.writers[replica], bound != Sharing.hash(writer) { throw ShareError.refused(403) }
                room.writers[replica] = Sharing.hash(writer)
            default:
                break
            }
            let once: Bool
            switch record {
            case .part, .picture, .versionDesign: once = true
            default: once = false
            }
            // Taken: the same as done, as the relay's 409 is to the Mac.
            if once, room.records[key] != nil { return }
            room.seq += 1
            room.records[key] = Record(seq: room.seq, data: body)
            rooms[id] = room
        }
    }

    func delete(_ id: String, _ key: String, write: String, writer: String) async throws {
        try lock.withLock {
            var room = try room(id, write, "write")
            guard case .part(let replica, _)? = ShareRecord(key: key), room.writers[replica] == Sharing.hash(writer) else { throw ShareError.refused(403) }
            guard room.records.removeValue(forKey: key) != nil else { return }
            room.seq += 1
            rooms[id] = room
        }
    }

    func unshare(_ id: String, write: String, owner: String) async throws {
        try lock.withLock {
            var room = try room(id, write, "write")
            guard room.hashes["owner"] == Sharing.hash(owner) else { throw ShareError.refused(403) }
            room = Room(hashes: room.hashes, gone: true)
            rooms[id] = room
        }
    }

    func keys(of id: String) -> [String] { lock.withLock { rooms[id].map { Array($0.records.keys) } ?? [] } }
}

/// Designs shared by link, through a room on the relay: here one of the tests' own, with each
/// design in a folder of its own as on two Macs.
@MainActor
@Suite(.serialized)
struct CloudShareTests {
    private struct Shared {
        let relay = MemoryRelay()
        /// The relay the Macs use: the tests' own, or the real one running at `BEZZLE_RELAY_TEST`.
        var server: ShareServer
        let keys: ShareKeys
        let secret: String
        let owner = ShareKeys.newSecret().base64URL
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleShare-\(UUID().uuidString)", isDirectory: true)

        init(server: ShareServer? = nil) {
            self.server = server ?? relay
            let secret = ShareKeys.newSecret()
            self.secret = secret.base64URL
            keys = ShareKeys(secret: secret)!
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        var link: ShareLink { ShareLink(secret: secret, title: "Poster", ownerName: "Anna") }
    }

    private func design(_ nodes: [Node]) -> BezzleDocument {
        var doc = BezzleDocument()
        doc.nodes = nodes
        return doc
    }

    private func start(_ shared: Shared) async throws -> Collaboration {
        Sharing.shared.server = shared.server
        try await shared.server.create(shared.keys.room, hashes: ["read": Sharing.hash(shared.keys.readToken),
                                                                 "write": Sharing.hash(shared.keys.writeToken),
                                                                 "owner": Sharing.hash(shared.owner)])
        Sharing.shared.own(shared.keys.room, with: shared.owner)
        let url = shared.folder.appendingPathComponent("Anna.bezzle")
        try DesignFile.write(design([CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50)),
                                     CanvasTests.rect("S", CGRect(x: 100, y: 10, width: 50, height: 50))]), to: url)
        try SharingFiles.write(shared.link, to: url)
        let anna = try #require(Collaboration.open(url, replica: "anna", claiming: false))
        try await anna.cloud?.sendMeta(ShareMeta(title: "Poster", owner: "Anna", made: 1))
        anna.cloud?.start(for: anna)
        await anna.cloud?.syncForTesting()
        return anna
    }

    /// Another Mac opening the link, as `Sharing.accept` makes the design.
    private func join(_ shared: Shared, as replica: String) async throws -> Collaboration {
        // One process stands for every Mac: the others never had the owner's token.
        Sharing.shared.disownForTesting(shared.keys.room)
        let arrived = try await CloudShare.download(shared.keys, from: shared.server) { _ in }
        let url = shared.folder.appendingPathComponent("\(replica).bezzle")
        try DesignFile.write(arrived.state.flatDesign().document(), to: url)
        try SharingFiles.write(ShareLink(secret: shared.secret, title: arrived.meta?.title, ownerName: arrived.meta?.owner), to: url)
        _ = FolderSync.open(url, replica: replica, seed: arrived.state)
        CloudShare.keep(arrived.progress, of: url, replica: replica)
        DocumentStore.finishSaving()
        let session = try #require(Collaboration.open(url, replica: replica, claiming: false))
        session.cloud?.start(for: session)
        return session
    }

    private func done(_ shared: Shared, _ sessions: [Collaboration]) {
        sessions.forEach { $0.close() }
        Sharing.shared.disownForTesting(shared.keys.room)
        Sharing.shared.server = nil
        DocumentStore.finishSaving()
        try? FileManager.default.removeItem(at: shared.folder)
    }

    private func edit(_ session: Collaboration, _ name: String, _ change: (inout Node) -> Void) {
        var doc = session.state.flatDesign().document()
        guard let id = doc.allNodes.first(where: { $0.name == name })?.id else { Issue.record("No layer \(name)"); return }
        doc.update(id, change)
        session.takeIn(doc)
    }

    private func layer(_ session: Collaboration, _ name: String) -> Node? {
        session.state.flatDesign().document().allNodes.first { $0.name == name }
    }

    @Test func aDesignSharedByLinkComesToAnotherMacAndBothKeepEachOthersChanges() async throws {
        let shared = Shared()
        let anna = try await start(shared)
        let ben = try await join(shared, as: "ben")
        defer { done(shared, [anna, ben]) }
        #expect(ben.state == anna.state)
        #expect(ben.mark == .sharedBy("Anna"))

        // At once: the same layer, different properties, and another layer.
        edit(anna, "R") { $0.frame.origin.x = 300 }
        edit(ben, "R") { $0.fill.color = .black }
        edit(ben, "S") { $0.name = "S, renamed" }
        await anna.cloud?.syncForTesting()
        await ben.cloud?.syncForTesting()
        await anna.cloud?.syncForTesting()
        for session in [anna, ben] {
            #expect(layer(session, "R")?.frame.minX == 300)
            #expect(layer(session, "R")?.fill.color == .black)
            #expect(layer(session, "S, renamed") != nil)
        }
        #expect(anna.state == ben.state)
        #expect(anna.cloud?.people["ben"]?.replica == "ben")
        // Everything on the relay is sealed: no layer's name is in any record.
        for key in shared.relay.keys(of: shared.keys.room) {
            let data = try #require(try await shared.relay.get(shared.keys.room, key, read: shared.keys.readToken))
            #expect(data.range(of: Data("renamed".utf8)) == nil, "\(key)")
        }
    }

    @Test func whatCameFromTheRoomIsKeptWithTheDesign() async throws {
        let shared = Shared()
        let anna = try await start(shared)
        let ben = try await join(shared, as: "ben")
        defer { done(shared, [anna]) }
        edit(anna, "S") { $0.name = "From Anna" }
        await anna.cloud?.syncForTesting()
        await ben.cloud?.syncForTesting()
        #expect(layer(ben, "From Anna") != nil)
        let url = ben.url
        ben.close()
        DocumentStore.finishSaving()
        // With no relay at all, it opens as it last was.
        Sharing.shared.server = nil
        let again = try #require(Collaboration.open(url, replica: "ben", claiming: false))
        #expect(layer(again, "From Anna") != nil)
        again.close()
    }

    @Test func picturesGoAndComeOnTheirOwn() async throws {
        let shared = Shared()
        let anna = try await start(shared)
        let ben = try await join(shared, as: "ben")
        defer { done(shared, [anna, ben]) }
        let picture = Data((0..<5000).map { UInt8($0 % 251) })
        let images = anna.url.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try picture.write(to: images.appendingPathComponent("photo.png"))
        anna.cloud?.offer(["photo.png"])
        await anna.cloud?.syncForTesting()
        // Named in the room only by what the link's keys make of it.
        let keys = shared.relay.keys(of: shared.keys.room)
        #expect(keys.contains("p.\(shared.keys.pictureName("photo.png"))"))
        #expect(!keys.contains { $0.contains("photo") })
        ben.cloud?.offer(["photo.png"])
        await ben.cloud?.syncForTesting()
        let arrived = ben.url.appendingPathComponent(DesignFile.imagesFolder).appendingPathComponent("photo.png")
        #expect((try? Data(contentsOf: arrived)) == picture)
    }

    @Test func manyChangesFoldAndSomeoneComingLaterHasThemAll() async throws {
        let shared = Shared()
        let anna = try await start(shared)
        let ben = try await join(shared, as: "ben")
        defer { done(shared, [anna, ben]) }
        for i in 1...60 {
            edit(anna, "R") { $0.frame.origin.x = CGFloat(i) }
            await anna.cloud?.syncForTesting()
            if i % 10 == 0 { await ben.cloud?.syncForTesting() }
        }
        await ben.cloud?.syncForTesting()
        #expect(layer(ben, "R")?.frame.minX == 60)
        let annas = shared.relay.keys(of: shared.keys.room).compactMap(FolderShare.Part.record).filter { $0.replica == "anna" }
        #expect(annas.count < 40)
        #expect(annas.filter { $0.part.kind == .whole }.count == 2)
        // Ben, following along, never needed Anna's wholes.
        for whole in annas where whole.part.kind == .whole {
            #expect(shared.relay.fetched[whole.part.record(of: "anna"), default: 0] <= 1)
        }
        let carl = try await join(shared, as: "carl")
        #expect(layer(carl, "R")?.frame.minX == 60)
        #expect(carl.state == anna.state)
        carl.close()
    }

    @Test func whenTheOwnerStopsSharingTheOthersKeepItReadOnly() async throws {
        let shared = Shared()
        let anna = try await start(shared)
        let ben = try await join(shared, as: "ben")
        defer { done(shared, [anna, ben]) }
        edit(anna, "R") { $0.name = "Last" }
        await anna.cloud?.syncForTesting()
        await ben.cloud?.syncForTesting()
        try await shared.relay.unshare(shared.keys.room, write: shared.keys.writeToken, owner: shared.owner)
        await ben.cloud?.syncForTesting()
        #expect(ben.isReadOnly)
        #expect(ben.mark == .ended)
        #expect(ben.cloud == nil)
        #expect(SharingFiles.link(of: ben.url)?.ended == true)
        #expect(layer(ben, "Last") != nil)
        // It stays as it last was.
        let before = ben.state
        edit(ben, "Last") { $0.name = "Changed anyway" }
        #expect(ben.state == before)
    }

    /// The same, through the relay itself (Relay/), running on this Mac: `cd Relay && npx wrangler
    /// dev --port 8790`, then the tests with `TEST_RUNNER_BEZZLE_RELAY_TEST=http://127.0.0.1:8790`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BEZZLE_RELAY_TEST"] != nil))
    func throughTheRelayItself() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["BEZZLE_RELAY_TEST"].flatMap(URL.init(string:)))
        let shared = Shared(server: RelayServer(base: address))
        let anna = try await start(shared)
        let ben = try await join(shared, as: "ben")
        defer { done(shared, [anna, ben]) }
        #expect(ben.state == anna.state)
        edit(anna, "R") { $0.frame.origin.x = 300 }
        edit(ben, "S") { $0.name = "S, renamed" }
        let picture = Data((0..<1_500_000).map { UInt8($0 % 251) })
        let images = anna.url.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try picture.write(to: images.appendingPathComponent("big.png"))
        anna.cloud?.offer(["big.png"])
        for _ in 0..<2 {
            await anna.cloud?.syncForTesting()
            await ben.cloud?.syncForTesting()
        }
        #expect(layer(ben, "R")?.frame.minX == 300)
        #expect(layer(anna, "S, renamed") != nil)
        #expect(anna.state == ben.state)
        #expect(anna.cloud?.problem == nil && ben.cloud?.problem == nil)
        ben.cloud?.offer(["big.png"])
        await ben.cloud?.syncForTesting()
        #expect((try? Data(contentsOf: ben.url.appendingPathComponent(DesignFile.imagesFolder).appendingPathComponent("big.png"))) == picture)
        // Many changes fold on the relay too.
        for i in 1...30 {
            edit(anna, "R") { $0.frame.origin.y = CGFloat(i) }
            await anna.cloud?.syncForTesting()
        }
        await ben.cloud?.syncForTesting()
        #expect(layer(ben, "R")?.frame.minY == 30)
        try await shared.server.unshare(shared.keys.room, write: shared.keys.writeToken, owner: shared.owner)
        await ben.cloud?.syncForTesting()
        #expect(ben.isReadOnly)
    }

    /// For the browser's own test (Web/tools/link.mjs --mac <file>), through the relay itself: run
    /// once, it shares a design and writes its link and the design as the Mac has it into the file;
    /// run again after the browser has edited it there, it reads the browser's edit back. Needs
    /// `TEST_RUNNER_BEZZLE_RELAY_TEST` and `TEST_RUNNER_BEZZLE_WEB_LINK=<file>`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BEZZLE_RELAY_TEST"] != nil
                   && ProcessInfo.processInfo.environment["BEZZLE_WEB_LINK"] != nil))
    func forTheBrowser() async throws {
        let env = ProcessInfo.processInfo.environment
        let address = try #require(env["BEZZLE_RELAY_TEST"].flatMap(URL.init(string:)))
        let file = URL(fileURLWithPath: try #require(env["BEZZLE_WEB_LINK"]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? Data(contentsOf: file), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let browser = json["browser"] as? [String: Any], let link = (json["link"] as? String).flatMap(URL.init(string:)) {
            // The browser has been: its edit comes back here, merged as the Mac merges everything.
            let keys = try #require(Sharing.secret(from: link).flatMap { ShareKeys(link: $0) })
            let arrived = try await CloudShare.download(keys, from: RelayServer(base: address)) { _ in }
            let doc = arrived.state.flatDesign().document()
            #expect(doc.allNodes.contains { $0.text == browser["text"] as? String })
            #expect(String(decoding: try encoder.encode(doc), as: UTF8.self) == browser["document"] as? String)
            #expect(arrived.state.layers.values.contains { layer in layer.fields.values.contains { $0.stamp.by == "webtest" } })
            try? FileManager.default.removeItem(at: file)
            return
        }
        Sharing.shared.server = RelayServer(base: address)
        let shared = Shared(server: RelayServer(base: address))
        try await shared.server.create(shared.keys.room, hashes: ["read": Sharing.hash(shared.keys.readToken),
                                                                 "write": Sharing.hash(shared.keys.writeToken),
                                                                 "owner": Sharing.hash(shared.owner)])
        Sharing.shared.own(shared.keys.room, with: shared.owner)
        let url = shared.folder.appendingPathComponent("For the browser.bezzle")
        var board = Node(kind: .artboard, name: "Poster", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        board.children = [AdaptTests.text("Hello from a Mac", 24, at: CGPoint(x: 20, y: 20)),
                          CanvasTests.rect("Card", CGRect(x: 20, y: 80, width: 200, height: 120))]
        try DesignFile.write(design([board]), to: url)
        try SharingFiles.write(shared.link, to: url)
        let anna = try #require(Collaboration.open(url, replica: "anna", claiming: false))
        try await anna.cloud?.sendMeta(ShareMeta(title: "For the browser", owner: "Anna", made: Collaboration.now))
        anna.cloud?.start(for: anna)
        await anna.cloud?.syncForTesting()
        let out: [String: Any] = ["link": try #require(shared.link.page).absoluteString,
                                  "document": String(decoding: try encoder.encode(anna.state.flatDesign().document()), as: UTF8.self)]
        try JSONSerialization.data(withJSONObject: out).write(to: file)
        done(shared, [anna])
    }
}
